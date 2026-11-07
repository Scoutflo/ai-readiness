#!/usr/bin/env python3
"""Local Cloud Mode assessment receipts. No provider calls or credential reads."""
import argparse, datetime as dt, fcntl, hashlib, json, os, re, subprocess, tempfile
from pathlib import Path

LANES = {'inventory', 'declared', 'permitted', 'reachable', 'observed'}
RESULTS = {'complete', 'partial', 'blocked', 'not-in-scope'}
REASONS = {'access_denied', 'read_failed', 'unsupported', 'not_configured', 'insufficient_evidence', 'not_needed'}

def need(value, message='invalid local assessment input'):
    if not value: raise ValueError(message)

def canon(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def safe(value): return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:/-]{0,255}', value) and '://' not in value

def pairs(values):
    result = {}
    for key, value in values:
        need(key not in result, 'duplicate JSON key'); result[key] = value
    return result

def read(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_size <= 8388608, 'missing, linked or oversized evidence')
    value = json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=lambda _: need(False, 'non-finite JSON'))
    canon(value)
    return value

def atomic(path, value):
    fd, temp = tempfile.mkstemp(prefix='.cloud-worklist-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream: stream.write(canon(value) + b'\n')
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def stamp(value, day):
    need(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value), 'strict UTC generation required')
    parsed = dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
    need(value[:10] == day and parsed <= dt.datetime.now(dt.timezone.utc), 'capture date/generation mismatch')

def local_file(folder, ref):
    need(isinstance(ref, str) and re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', ref) and '..' not in ref.split('/'), 'unsafe evidence reference')
    path = folder / ref
    need(path.is_file() and not path.is_symlink() and folder in path.resolve().parents and path.stat().st_size <= 8388608, 'missing, linked or oversized capture')
    return path

def selected_metadata(config, target):
    parts = target.split('/')
    need(len(parts) <= 2 and parts[0] in {'aws', 'gcp', 'azure', 'digitalocean'} and all(safe(p) and '/' not in p for p in parts), 'select one supported cloud target')
    need(config.is_file(), 'selected config missing')
    tt = Path(__file__).resolve().parents[3] / 'report-standard/toolkit-targets.sh'
    def query(*args):
        return subprocess.run(['sh', str(tt), str(config), parts[0], *map(str,args)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10).stdout.strip()
    count = int(query('count')); kind = query('kind'); need(count > 0, 'target not configured')
    if kind == 'seq':
        need(len(parts) == 2, 'labeled cloud list requires explicit target label')
        matches = [i for i in range(count) if query('label', i) == parts[1]]
        need(len(matches) == 1, 'selected cloud label must resolve exactly once'); index = matches[0]
    else:
        need(len(parts) == 1 and count == 1, 'single cloud block uses unqualified provider target'); index = 0
    keys = {'aws': ['profile', 'region'], 'gcp': ['project', 'region', 'credentials_env'], 'azure': ['subscription_id', 'tenant_id'], 'digitalocean': ['token_env']}[parts[0]]
    metadata = {key: query('get', index, key) for key in keys}
    required = {'aws': ['profile', 'region'], 'gcp': ['project'], 'azure': ['subscription_id'], 'digitalocean': ['token_env']}[parts[0]]
    need(all(metadata[key] for key in required), 'selected cloud metadata incomplete')
    return hashlib.sha256(canon([target, metadata])).hexdigest()

def capture_binding(catalog, folder, target):
    need(isinstance(catalog, dict) and set(catalog) == {'schema','target','audit_date','observed_at','collection','services','captures'})
    need(catalog['schema'] == 'scoutflo-cloud-topology-catalog/v1' and catalog['target'] == target, 'catalog target mismatch')
    day = catalog['audit_date']; need(isinstance(day, str)); dt.date.fromisoformat(day); stamp(catalog['observed_at'], day)
    collection = catalog['collection']; need(isinstance(collection, dict) and set(collection) == {'status','scope'})
    need(collection['status'] in {'complete','partial','blocked','unknown'} and collection['scope'] in {'target','subset','unknown'})
    need(collection['status'] != 'complete' or collection['scope'] == 'target', 'complete source requires target scope')
    rows = catalog['services']; need(isinstance(rows, list) and 1 <= len(rows) <= 50000, 'nonempty bounded service denominator required')
    for row in rows:
        need(isinstance(row, dict) and set(row) == {'id','kind','lanes'} and safe(row['id']) and safe(row['kind']))
        need(isinstance(row['lanes'], list) and row['lanes'] and len(set(row['lanes'])) == len(row['lanes']) and set(row['lanes']) <= LANES)
    need(len({r['id'] for r in rows}) == len(rows), 'duplicate service identity')
    captures = catalog['captures']; need(isinstance(captures, list) and len(captures) <= 1000)
    need(captures or collection['status'] in {'blocked','unknown'}, 'readable source needs capture evidence')
    bindings = {}
    for item in captures:
        need(isinstance(item, dict) and set(item) == {'ref','sha256','observed_at'})
        stamp(item['observed_at'], day); need(item['observed_at'] <= catalog['observed_at'], 'capture occurs after catalog completion')
        path = local_file(folder, item['ref']); need(item['ref'] not in bindings and digest(path) == item['sha256'], 'capture digest changed')
        bindings[item['ref']] = {'sha256':item['sha256'], 'observed_at':item['observed_at']}
    return rows, bindings

def validate_proof(proof, state, claimed, folder, expected, capture_hashes):
    need(isinstance(proof, dict) and set(proof) == {'schema','run_id','binding_sha256','services'})
    need(proof['schema'] == 'scoutflo-cloud-topology-assessment/v1' and proof['run_id'] == state['run_id'] and proof['binding_sha256'] == hashlib.sha256(canon(state['binding'])).hexdigest(), 'assessment generation mismatch')
    services = proof['services']; need(isinstance(services, list) and services and len(services) == len(claimed))
    need({x['id'] for x in services} == claimed and len({x['id'] for x in services}) == len(services), 'receipt must cover the exact claimed services')
    for service in services:
        need(set(service) == {'id','checks'} and isinstance(service['checks'], list))
        checks = service['checks']; need({c['lane'] for c in checks} == expected[service['id']] and len(checks) == len(expected[service['id']]), 'every declared lane needs an assessment')
        for check in checks:
            need(set(check) == {'lane','result','reason','evidence'} and check['result'] in RESULTS and isinstance(check['evidence'], list))
            need(check['reason'] is None if check['result'] == 'complete' else check['reason'] in REASONS)
            need(check['result'] != 'complete' or check['evidence'], 'complete assessment needs retained evidence')
            refs = set()
            for item in check['evidence']:
                need(isinstance(item, dict) and set(item) == {'ref','sha256','observed_at'})
                stamp(item['observed_at'], state['binding']['audit_date'])
                source = state['binding']['captures'].get(item['ref'])
                if source is not None:
                    need(item['observed_at'] == source['observed_at'] and item['sha256'] == source['sha256'], 'bound source capture generation differs')
                else:
                    need(item['observed_at'] >= state['binding']['source_generation'], 'new assessment evidence predates collection completion')
                path = local_file(folder, item['ref'])
                if path not in capture_hashes: capture_hashes[path] = digest(path)
                need(item['ref'] not in refs and capture_hashes[path] == item['sha256'], 'assessment capture changed')
                refs.add(item['ref'])

def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--catalog', required=True, type=Path); parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--target', required=True); parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--new-run', action='store_true'); parser.add_argument('command', choices=['init','claim','done','status','finish']); parser.add_argument('argument', nargs='?')
    args = parser.parse_args(); os.umask(0o077)
    metadata = selected_metadata(args.config, args.target)
    catalog_path = args.catalog.absolute(); catalog = read(catalog_path); folder = catalog_path.parent.resolve()
    rows, captures = capture_binding(catalog, folder, args.target)
    binding = {'target':args.target,'config_metadata_sha256':metadata,'audit_date':catalog['audit_date'],'catalog_sha256':digest(catalog_path),'source_generation':catalog['observed_at'],'captures':captures}
    runs = args.root / 'map-topology' / 'cloud-runs' / args.target.replace('/', '__'); runs.mkdir(parents=True, exist_ok=True)
    need(not runs.is_symlink()); active = runs / 'active.json'
    fd = os.open(runs / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = read(active) if active.exists() else None
        if args.new_run:
            need(args.command == 'init' and (state is None or all(r['status'] == 'done' for r in state['rows'])), 'finish pending work before a new run')
            if state is not None: atomic(runs / (state['run_id'] + '.json'), state)
            state = None
        if state is None:
            need(args.command == 'init', 'initialize selected assessment first')
            state = {'schema':'scoutflo-cloud-topology-worklist/v1','run_id':dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'),'binding':binding,'rows':[dict(r,status='pending') for r in rows]}
        need(state['schema'] == 'scoutflo-cloud-topology-worklist/v1' and state['binding'] == binding, 'target, metadata, scope or capture generation drift; resume matching evidence or explicitly initialize a new completed generation')
        expected = {r['id']:r for r in rows}
        need(len(state['rows']) == len(rows) and {r['id'] for r in state['rows']} == set(expected))
        need(all(r['status'] in {'pending','claimed','done'} and r['lanes'] == expected[r['id']]['lanes'] and r['kind'] == expected[r['id']]['kind'] for r in state['rows']))
        lane_map = {key:set(row['lanes']) for key,row in expected.items()}; capture_hashes = {}
        if args.command == 'claim':
            size = int(args.argument or '10'); need(1 <= size <= 100, 'batch size must be 1..100')
            selected = [r for r in state['rows'] if r['status'] == 'claimed'] or [r for r in state['rows'] if r['status'] == 'pending'][:size]
            for row in selected: row['status'] = 'claimed'
            print(json.dumps({'run_id':state['run_id'],'binding_sha256':hashlib.sha256(canon(binding)).hexdigest(),'services':[{'id':r['id'],'lanes':r['lanes']} for r in selected]}))
        elif args.command == 'done':
            need(args.argument, 'assessment receipt required'); proof_path = Path(args.argument).absolute()
            need(folder in proof_path.resolve().parents and not proof_path.is_symlink(), 'receipt must be retained beside selected evidence')
            proof_path = proof_path.resolve()
            need(all(r.get('receipt') != str(proof_path.relative_to(folder)) for r in state['rows'] if r['status']=='done'), 'use a distinct receipt file for each batch')
            claimed = {r['id'] for r in state['rows'] if r['status']=='claimed'}; proof = read(proof_path)
            validate_proof(proof, state, claimed, folder, lane_map, capture_hashes)
            for row in state['rows']:
                if row['id'] in claimed: row.update(status='done',receipt=str(proof_path.relative_to(folder)),receipt_sha256=digest(proof_path))
        elif args.command == 'finish':
            need(all(r['status'] == 'done' for r in state['rows']), 'assessment worklist incomplete; do not publish a finished map')
            groups = {}
            for row in state['rows']: groups.setdefault(row['receipt'], []).append(row)
            for ref, members in groups.items():
                path = local_file(folder, ref); peers = {r['id'] for r in members}
                proof_digest = digest(path)
                need(all(proof_digest==r['receipt_sha256'] for r in members), 'assessment receipt changed')
                validate_proof(read(path), state, peers, folder, lane_map, capture_hashes)
            print(json.dumps({'assessment_complete':True,'services':len(rows),'source_collection':catalog['collection'],'collection_completeness_proven':False,'note':'Completed assessments include explicit blocked/partial lanes; report those coverage gaps separately.'}))
        elif args.command in {'init','status'}:
            print(json.dumps({'run_id':state['run_id'],'binding_sha256':hashlib.sha256(canon(binding)).hexdigest(),'counts':{s:sum(r['status']==s for r in state['rows']) for s in ['pending','claimed','done']}}))
        atomic(active, state)

if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError, StopIteration):
        raise SystemExit('CLOUD-TOPOLOGY-WORKLIST-BLOCKED: selected metadata, capture generation, lock or exact assessment receipt is unavailable or changed.')
