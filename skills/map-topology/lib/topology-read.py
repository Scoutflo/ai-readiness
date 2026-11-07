#!/usr/bin/env python3
"""Fixed read-only Kubernetes recipes; project before printing or persistence."""
import json, os, re, subprocess, sys
from urllib.parse import urlsplit, urlunsplit

SAFE = re.compile(r'^[A-Za-z0-9_.:/@*+%=-]{0,512}$')
SENSITIVE = re.compile(r'password|passwd|secret|token|api.?key|credential|authorization', re.I)
ALIASES={'ns':'namespace','namespaces':'namespace','svc':'service','services':'service','pods':'pod','deployments':'deployment','statefulsets':'statefulset','daemonsets':'daemonset','ingresses':'ingress','virtualservices':'virtualservice','destinationrules':'destinationrule','serviceentries':'serviceentry'}
SUPPORTED={'namespace','service','pod','deployment','statefulset','daemonset','ingress','endpoints','virtualservice','destinationrule','serviceentry','gateways.networking.istio.io','applications.argoproj.io'}

def read_arguments(kind,args):
    # These fixed recipes require only all-namespaces or one namespace. Never
    # pass through target, credential, output, raw API, file or watch flags.
    kinds=kind.split(',')
    if not kinds or len(kinds)!=len(set(kinds)) or any(ALIASES.get(k,k) not in SUPPORTED for k in kinds):
        raise ValueError('unsupported projection kind; no provider call made')
    if not args or args in (['-A'],['--all-namespaces']):return
    if len(args)==2 and args[0] in {'-n','--namespace'} and re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',args[1]):return
    if len(args)==1 and args[0].startswith('--namespace=') and re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',args[0][12:]):return
    raise ValueError('unsupported Kubernetes read arguments; no provider call made')

def scalar(v):
    if isinstance(v, (int, float, bool)) or v is None: return v
    if not isinstance(v, str) or not SAFE.fullmatch(v): return None
    if '://' in v or '?' in v or '#' in v or '@' in v and not re.search(r'@sha256:[a-f0-9]+$',v): return None
    return v

def selected(obj, keys):
    if not isinstance(obj, dict): return {}
    return {k: scalar(obj[k]) for k in keys if k in obj and scalar(obj[k]) is not None}

def labels(v):
    return {k: scalar(val) for k,val in (v or {}).items() if isinstance(k,str) and not SENSITIVE.search(k) and scalar(k) is not None and scalar(val) is not None} if isinstance(v,dict) else {}

def meta(obj):
    out=selected(obj, ['name','namespace','uid']);out['labels']=labels(obj.get('labels',{}));return out

def container(c):
    # env values, envFrom contents, commands/args, mounts and annotations never leave memory.
    out=selected(c,['name','image','restartPolicy'])
    out['env_names']=[scalar(e.get('name')) for e in c.get('env',[])]
    out['env_from_references']=[dict(kind=k,source=selected(e[k],['name']),**selected(e,['prefix'])) for e in c.get('envFrom',[]) for k in ['secretRef','configMapRef'] if k in e]
    out['env_references']=[{'name':scalar(e.get('name')),'source':selected(e.get('valueFrom',{}).get(kind,{}),['name','key']) ,'kind':{'namespace':'Namespace','deployment':'Deployment','statefulset':'StatefulSet','daemonset':'DaemonSet'}.get(kind,kind)} for e in c.get('env',[]) for kind in ['secretKeyRef','configMapKeyRef'] if kind in e.get('valueFrom',{})]
    return out

def pod(spec):
    return {k:[container(c) for c in spec.get(k,[])] for k in ['containers','initContainers']}

def project(kind, doc):
    if ',' in kind:
        if not isinstance(doc,dict) or not isinstance(doc.get('items'),list):raise ValueError('expected Kubernetes list')
        return {'items':[project(x.get('kind','').lower(),{'items':[x]})['items'][0] for x in doc['items']], 'projection':'scoutflo-topology-kubernetes/v1'}
    kind=ALIASES.get(kind,kind)
    if kind not in SUPPORTED: raise ValueError('unsupported projection kind')
    if not isinstance(doc,dict) or not isinstance(doc.get('items'),list): raise ValueError('expected Kubernetes list')
    out=[]
    for item in doc['items']:
        m=item.get('metadata',{});s=item.get('spec',{});row={'metadata':meta(m),'kind':{'namespace':'Namespace','deployment':'Deployment','statefulset':'StatefulSet','daemonset':'DaemonSet'}.get(kind,kind)};sp={}
        if kind in {'deployment','statefulset','daemonset'}:
            t=s.get('template',{});sp={'template':{'metadata':meta(t.get('metadata',{})),'spec':pod(t.get('spec',{}))}}
        elif kind=='pod':sp=pod(s)
        elif kind=='service':
            sp=selected(s,['type','externalName','clusterIP']);sp['selector']=labels(s.get('selector',{}));sp['selector_projection_complete']=sp['selector']==s.get('selector',{});sp['ports']=[selected(x,['port','protocol','targetPort','name']) for x in s.get('ports',[])]
        elif kind=='endpoints':row['subsets']=[{'addresses':[selected(a,['ip','hostname']) for a in x.get('addresses',[])]} for x in item.get('subsets',[])]
        elif kind=='ingress':sp={'rules':[{'host':scalar(x.get('host')),'http':{'paths':[dict(path=scalar(p.get('path')),backend={'service':dict(name=scalar(p.get('backend',{}).get('service',{}).get('name')),port=selected(p.get('backend',{}).get('service',{}).get('port',{}),['name','number']))}) for p in x.get('http',{}).get('paths',[])]}} for x in s.get('rules',[])]}
        elif kind=='virtualservice':
            sp={k:[scalar(v) for v in s[k]] for k in ['hosts','gateways'] if k in s}
            for protocol in ['http','tcp','tls']:
                sp[protocol]=[{'route':[dict(destination=selected(r.get('destination',{}),['host','subset','port']),**selected(r,['weight'])) for r in x.get('route',[])], 'delegate':selected(x.get('delegate',{}),['name','namespace'])} for x in s.get(protocol,[])]
        elif kind=='destinationrule':sp={'host':scalar(s.get('host')),'subsets':[dict(name=scalar(x.get('name')),labels=labels(x.get('labels',{}))) for x in s.get('subsets',[])]}
        elif kind=='serviceentry':sp=dict(selected(s,['location','resolution']),hosts=[scalar(v) for v in s.get('hosts',[])])
        elif kind=='gateways.networking.istio.io':sp={'servers':[dict(port=selected(x.get('port',{}),['number','protocol']),hosts=[scalar(v) for v in x.get('hosts',[])]) for x in s.get('servers',[])]}
        elif kind=='applications.argoproj.io':
            def source(x):
                q=selected(x,['path','targetRevision','chart']);u=urlsplit(x.get('repoURL',''))
                if u.scheme in {'http','https','ssh'} and u.hostname and not u.username and not u.password and not u.query and not u.fragment:q['repoURL']=urlunsplit((u.scheme,u.netloc,u.path,'',''))
                elif re.fullmatch(r'git@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+',x.get('repoURL','')):q['repoURL']=x['repoURL']
                return q
            sp={'sources':[source(x) for x in s.get('sources',[])],'destination':selected(s.get('destination',{}),['namespace'])}
            # An absent singular source must stay absent so sources[0] remains
            # usable by the documented multi-source fallback in the recipe.
            if 'source' in s and s['source'] is not None:sp['source']=source(s['source'])
            st=item.get('status',{});sync=st.get('sync',{});row['status']={'resources':[selected(x,['kind','name','namespace']) for x in st.get('resources',[])],'sync':dict(selected(sync,['revision']),revisions=[scalar(x) for x in sync.get('revisions',[])])}
        row['spec']=sp;out.append(row)
    return {'items':out,'projection':'scoutflo-topology-kubernetes/v1'}

def read(kind, args):
    context=os.environ.get('KUBE_CONTEXT')
    if not context:raise ValueError('selected context required')
    read_arguments(kind,args)
    result=subprocess.run(['kubectl','--context',context,'get',kind,*args,'-o','json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
    if result.returncode: raise ValueError('Kubernetes read denied or unavailable; no absence conclusion')
    if len(result.stdout)>64*1024*1024:raise ValueError('list exceeds capture bound; use namespace batches')
    return project(kind,json.loads(result.stdout))

if __name__=='__main__':
    try:
        if sys.argv[1]=='get':doc=read(sys.argv[2],sys.argv[3:])
        elif sys.argv[1]=='project':doc=project(sys.argv[2],json.load(sys.stdin))
        else:raise ValueError('unsupported command')
        print(json.dumps(doc,allow_nan=False))
    except (ValueError,KeyError,TypeError,OSError,subprocess.TimeoutExpired) as error:
        raise SystemExit('TOPOLOGY-READ-BLOCKED: '+str(error))
