#!/usr/bin/env python3
"""Resolve exact host openings against explicitly selected, scoped local catalogs."""
import datetime, ipaddress, json, re, sys
from pathlib import Path

def pairs(items):
    out={}
    for key,value in items:
        if key in out:raise ValueError('duplicate JSON key')
        out[key]=value
    return out

def main():
    doc=json.loads(Path(sys.argv[1]).read_text(),object_pairs_hook=pairs)
    if doc.get('schema')!='scoutflo-topology-ip-catalog/v1':raise ValueError('unsupported catalog schema')
    day=datetime.date.fromisoformat(doc['audit_date']);targets=set();owners={};complete=True
    for src in doc['sources']:
        target=src['target']
        if not re.fullmatch(r'[a-z0-9_-]+/[A-Za-z0-9_.-]+',target) or target in targets:raise ValueError('unique qualified catalog targets required')
        targets.add(target)
        stamp=datetime.datetime.strptime(src['observed_at'],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        if stamp.date()!=day or stamp>datetime.datetime.now(datetime.timezone.utc):raise ValueError('stale or future catalog')
        if src['status'] not in {'complete','partial','blocked','unknown'}:raise ValueError('invalid catalog collection status')
        complete &= src['status']=='complete'
        for row in src['records']:
            ip=str(ipaddress.ip_address(row['ip']));owner=row['owner']
            if not re.fullmatch(r'[A-Za-z0-9_.:/-]{1,512}',owner):raise ValueError('unsafe owner identifier')
            owners.setdefault(ip,set()).add((target,owner))
    if len(targets)<2:raise ValueError('select at least two provider targets for cross-cloud attribution')
    for line in Path(sys.argv[2]).read_text().splitlines():
        address,resource=line.split('\t')
        if not re.fullmatch(r'[A-Za-z0-9_.:/-]{1,512}',resource):raise ValueError('unsafe resource identifier')
        network=ipaddress.ip_network(address,strict=False)
        if network.num_addresses!=1:print('OPEN\t'+resource+'\twide CIDR; no per-owner edge');continue
        ip=str(network.network_address);matches=owners.get(ip,set())
        if len(matches)>1:print('AMBIGUOUS\t'+resource+'\tshared address; '+str(len(matches))+' candidate owners');continue
        if not complete:print('UNKNOWN\t'+resource+'\tselected catalog incomplete; ownership cannot be unique');continue
        if not matches:print('OPEN\t'+resource+'\tunattributed within selected catalogs');continue
        target,owner=next(iter(matches));print('CANDIDATE\t'+target+'\t'+owner+'\t'+resource+'\treachable only; requires review')

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError) as e:raise SystemExit('TOPOLOGY-IP-BLOCKED: '+str(e))
