#!/bin/sh
# Scoped audit results must retain their boundary in every shared report view.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "${SCOUTFLO_TEST_RENDERER:-$ROOT/report-standard/render-report-viz.sh}" <<'PY'
import copy, json, pathlib, subprocess, sys, tempfile
renderer = sys.argv[2]
day = '2026-11-05'
checks = [{'id': f'SOC-{n:03}', 'category': 'Fixture', 'result': 'pass'} for n in range(1, 8)]
base = {'schema': 'scoutflo-findings/v2', 'skill': 'audit-splunk-oncall',
        'target': 'splunk_oncall', 'run_date': day, 'generated_at': day+'T12:00:00Z',
        'scope': 'selected-policies', 'checks': checks, 'findings': [],
        'score': {'overall': 100, 'state': 'assessed', 'end_to_end': False,
                  'categories': [], 'excluded': [],
                  'assessment': {'applicable_checks': 7, 'assessed_checks': 7,
                                 'scored_checks': 7, 'blocked_checks': 0,
                                 'suppressed_checks': 0, 'not_in_scope_checks': 0,
                                 'coverage_percent': 100}},
        'severity_counts': {'critical': 0, 'high': 0, 'medium': 0, 'low': 0, 'info': 0}}
inventory = {'schema': 'scoutflo-inventory/v1', 'target': 'splunk_oncall',
             'generated_at': day+'T12:00:00Z', 'counts': {'total': 1, 'by_kind': {'team': 1}},
             'items': [{'name': 'team-fixture', 'kind': 'team'}]}
passed = 0
def check(label, result):
    global passed
    assert result, label
    passed += 1
    print('PASS:', label)
def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))
def render(mode, *args):
    p = subprocess.run(['/bin/sh', renderer, mode, *map(str, args)], capture_output=True, text=True)
    assert p.returncode == 0, (mode, p.stderr)
    return p.stdout
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    for target in ['splunk_oncall', 'splunk_oncall/secondary', 'splunk_oncall/all']:
        root = tmp/target.replace('/', '-')
        folder = root/target/day
        f, inv = folder/'findings.json', folder/'inventory.json'
        doc, items = copy.deepcopy(base), copy.deepcopy(inventory)
        doc['target'] = items['target'] = target
        write(f, doc); write(inv, items)
        for mode, args in [('at-a-glance', [f]), ('rollup', [root, day]),
                           ('exec-summary', [root, day]), ('inventory', [inv]),
                           ('inventory-rollup', [root, day])]:
            text = render(mode, *args)
            check(target+' '+mode+' retains scope', 'selected-policies' in text)
            check(target+' '+mode+' never invents completeness',
                  'Complete current-state catalog' not in text and 'Everything the configured stacks have' not in text)
        text = render('exec-summary', root, day)
        check(target+' zero-finding audit is counted', 'across 1 stack(s)' in text)
        check(target+' selected pass is not HEALTHY', 'HEALTHY' not in text)
        check(target+' environment comparison retains scope', 'selected-policies' in render('env-compare', day, 'qa', root))
        out = folder/'report.html'; render('html', f, out)
        check(target+' HTML retains scope and readiness boundary',
              'selected-policies' in out.read_text() and 'not end-to-end' in out.read_text())
        check(target+' report render is read-only', json.loads(f.read_text()) == doc and json.loads(inv.read_text()) == items)
        for scope in [None, 'full', 'account']:
            d = copy.deepcopy(doc)
            if scope is None: d.pop('scope')
            else: d['scope'] = scope
            write(f, d)
            check(target+' historical/full scope '+str(scope), 'Scoped assessment:' not in render('at-a-glance', f))
        d = copy.deepcopy(doc); d['scope'] = 'triage'; write(f, d)
        check(target+' triage remains explicit', 'TRIAGE' in render('exec-summary', root, day))
        d = copy.deepcopy(doc); d['scope'] = '<script>alert(1)</script>|`'; write(f, d)
        render('html', f, out)
        check(target+' scope is escaped', '<script>alert(1)</script>' not in out.read_text() and '&lt;script&gt;' in out.read_text())
        d = copy.deepcopy(doc); d['score']['overall'] = None; d['score']['state'] = 'unassessed'
        d['score']['assessment'].update(scored_checks=0, assessed_checks=0, blocked_checks=7, coverage_percent=0)
        d['checks'] = [dict(c, result='blocked') for c in d['checks']]
        d['findings'] = [{'id': 'SOC-006', 'severity': 'high', 'status': 'blocked', 'lifecycle': 'new', 'title': 'Requirement not established'}]
        write(f, d)
        text = render('exec-summary', root, day)
        check(target+' blocked is unassessed, not healthy or a confirmed high gap',
              'UNASSESSED OR PARTIAL' in text and '7 check(s) are blocked' in text and '0 high' in text and 'HEALTHY' not in text)
        d['findings'] = []; write(f, d)
        check(target+' zero findings cannot clear blocked checks', 'UNASSESSED OR PARTIAL' in render('exec-summary', root, day))
        write(f, dict(doc, target='another-target'))
        check(target+' inventory rejects mismatched scope target', 'selected-policies' not in render('inventory', inv))
        write(f, dict(doc, run_date='2026-11-04'))
        check(target+' inventory rejects mismatched scope date', 'selected-policies' not in render('inventory', inv))
        write(f, dict(doc, scope='full'))
        write(inv, dict(items, scope='inventory-subset'))
        check(target+' explicit inventory scope overrides full sibling', 'inventory-subset' in render('inventory', inv))
        write(inv, dict(items, scope='inventory-subset', items=[], counts={'total': 0, 'by_kind': {}}))
        check(target+' empty inventory retains its explicit scope', 'inventory-subset' in render('inventory', inv))
        write(inv, items)
        write(f, doc)
        # A separate full audit with no findings still contributes a stack.
        full = copy.deepcopy(doc); full.update(target='grafana', skill='audit-grafana', scope='full')
        full['score']['end_to_end'] = True; write(root/'grafana'/day/'findings.json', full)
        check(target+' mixed full/scoped count', 'across 2 stack(s)' in render('exec-summary', root, day))
        legacy = copy.deepcopy(full); legacy['schema'] = 'scoutflo-findings/v1'
        legacy.pop('scope'); legacy.pop('checks'); legacy['score'].pop('assessment'); legacy['score'].pop('end_to_end')
        legacy_root = tmp/(target.replace('/', '-')+'-legacy')
        write(legacy_root/'grafana'/day/'findings.json', legacy)
        check(target+' legacy v1 remains readable', 'HEALTHY on what ran' in render('exec-summary', legacy_root, day))
        render('html', legacy_root/'grafana'/day/'findings.json', out)
        check(target+' legacy v1 HTML does not invent readiness flags', 'not end-to-end' not in out.read_text())
        cost = {'schema': 'scoutflo-cost/v1', 'target': 'cost', 'findings': [
            {'id': 'COST-AWS-008', 'title': 'Native saving', 'severity': 'low',
             'estimated_monthly_savings_usd': 25, 'recommendation': 'Review the native recommendation.'}]}
        cost_root = tmp/(target.replace('/', '-')+'-cost')
        write(cost_root/'grafana'/day/'findings.json', full)
        write(cost_root/'cost'/day/'findings.json', cost)
        text = render('exec-summary', cost_root, day)
        check(target+' cost does not create a missing readiness score', 'HEALTHY on what ran' in text and 'across 1 stack(s)' in text)
        check(target+' cost lever remains ranked', 'Native saving' in text and '$25/mo' in text)
        (cost_root/'grafana'/day/'findings.json').unlink()
        check(target+' cost-only cannot certify readiness', 'NO READINESS ASSESSMENT' in render('exec-summary', cost_root, day))
    reserved_root = tmp/'all'/'reports'
    write(reserved_root/'splunk_oncall'/day/'findings.json', base)
    check('audit root may contain reserved-looking directory names', 'across 1 stack(s)' in render('exec-summary', reserved_root, day))
    # Historical metadata can describe a shared host. Each resolved target
    # directory is still an independently selected audit in the estate.
    structured_root = tmp/'structured-targets'
    for target_label in ['alpha', 'beta']:
        historical = copy.deepcopy(legacy)
        historical['target'] = {'type': 'signoz', 'host': 'shared.example.invalid'}
        write(structured_root/'signoz'/target_label/day/'findings.json', historical)
    check('legacy structured target metadata cannot collapse distinct target directories',
          'across 2 stack(s)' in render('exec-summary', structured_root, day))
print(f'Report scope: {passed} passed; zero provider calls')
PY
