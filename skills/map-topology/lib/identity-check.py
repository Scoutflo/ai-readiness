#!/usr/bin/env python3
"""Local T1/T2 structural checks; never treats names alone as workload identity."""
import json, sys

def nonempty(value):return isinstance(value,str) and bool(value.strip())
def check(doc):
    resources=doc.get('resources',[]);edges=doc.get('relationships',[]);services=doc.get('services',[])
    cluster=doc.get('cluster',{}).get('cluster_id')
    rows=[]
    for svc in services:
        attrs=svc.get('attributes',{});reasons=[]
        t1=all(nonempty(svc.get(k)) for k in ['name','service_type','environment','business_criticality']) and all(nonempty(attrs.get(k)) for k in ['service_name','namespace','cluster_id'])
        if nonempty(cluster) and attrs.get('cluster_id') != cluster:t1=False
        if svc.get('environment') not in {'prod','staging','dev'} or svc.get('business_criticality') not in {'low','medium','high','critical'}:t1=False
        if not t1:reasons.append('service identity missing or contradicts map cluster')
        links=[e for e in edges if e.get('relation')=='DEPLOYED_AS' and e.get('from',{}).get('name')==svc.get('name')]
        t2=bool(links) and t1
        if not links:reasons.append('no DEPLOYED_AS edge')
        for edge in links:
            matches=[r for r in resources if r.get('name')==edge.get('to',{}).get('name')]
            valid=edge.get('from',{}).get('entity_type')=='service' and edge.get('to',{}).get('entity_type')=='resource' and len(matches)==1
            if valid:
                resource=matches[0];wa=resource.get('attributes',{});kind=resource.get('resource_type','')
                valid=all(nonempty(wa.get(k)) for k in ['cluster_id','namespace','workload_name','workload_type']) and wa.get('cluster_id')==attrs.get('cluster_id') and wa.get('namespace')==attrs.get('namespace') and kind=={'deployment':'kubernetes_deployment','statefulset':'kubernetes_stateful_set','daemonset':'kubernetes_daemon_set','job':'kubernetes_job','cronjob':'kubernetes_cron_job'}.get(wa.get('workload_type'))
            if not valid:t2=False;reasons.append('DEPLOYED_AS endpoint or cluster/namespace/workload tuple is invalid')
        rows.append(dict(service=svc.get('name'),t1=t1,t2=t2,reasons=sorted(set(reasons))))
    return rows

if __name__=='__main__':
    try:
        doc=json.load(open(sys.argv[1]));rows=check(doc)
        print('service\tT1-identity\tT2-workload\treason')
        for r in rows:print('\t'.join([str(r['service']),'pass' if r['t1'] else 'fail','pass' if r['t2'] else 'fail','; '.join(r['reasons'])]))
        if not rows or any(not r['t1'] or not r['t2'] for r in rows):raise SystemExit(1)
    except (ValueError,KeyError,TypeError,OSError) as e:raise SystemExit('TOPOLOGY-IDENTITY-BLOCKED: '+str(e))
