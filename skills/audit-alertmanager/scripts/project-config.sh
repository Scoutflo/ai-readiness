#!/bin/sh
# Stateless, local projection only. No provider calls, files or secret hashes.
set -eu
set +x
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1 || {
  echo 'Alertmanager config projection requires Python 3 with PyYAML; stop before provider reads.' >&2
  exit 2
}
if [ "${1:-}" = check ]; then
  AM_CURL_VERSION=$(curl --version 2>/dev/null | awk 'NR==1 {print $2}')
  printf '%s\n' "$AM_CURL_VERSION" | awk -F. '$1>8 || ($1==8 && $2>=4) {ok=1} END {exit !ok}' || {
    echo 'Alertmanager status reads require curl 8.4 or newer; stop before provider reads.' >&2
    exit 2
  }
  exit 0
fi
exec python3 -c '
import ipaddress, json, re, sys
from urllib.parse import urlsplit
import yaml

LIMIT = 2097152
def need(ok):
    if not ok: raise ValueError()
class StrictLoader(yaml.SafeLoader): pass
def pairs(items):
    out = {}
    for k,v in items:
        need(isinstance(k,str) and k not in out)
        out[k] = v
    return out
def mapping(loader,node):
    return pairs((loader.construct_object(k),loader.construct_object(v)) for k,v in node.value)
StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,mapping)
def decode_json(s): return json.loads(s,object_pairs_hook=pairs)
def text(v):
    need(isinstance(v,str) and len(v)<=2048 and not any(ord(c)<32 for c in v))
    # Even nominal identity/matcher fields can contain an incoming URL. Refuse
    # unsupported text rather than mask it into a false route-identity match.
    need(not re.search(r"(?i)[a-z][a-z0-9+.-]*://|X-VO-Api-(?:Id|Key)\s*[:=]",v.replace("\\/","/")))
    return v
def label(v):
    v=text(v); need(bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*|\.\.\.",v))); return v
secret = re.compile(r"url|key|token|secret|password|credential|authorization|routing",re.I)
def scalar(v):
    if isinstance(v,str): return text(v)
    need(v is None or type(v) in (bool,int,float)); return v
def normalize_key(k): return re.sub(r"(?<!^)([A-Z])",r"_\1",text(k)).lower()
budget=[0]
def bounded(v,depth=0,seen=None):
    budget[0]+=1; need(depth<=30 and budget[0]<=50000)
    if isinstance(v,(dict,list)):
        seen=set() if seen is None else seen; need(id(v) not in seen); seen=seen|{id(v)}
        for x in (v.values() if isinstance(v,dict) else v): bounded(x,depth+1,seen)
    else: need(v is None or type(v) in (str,bool,int,float))
def names(v):
    need(isinstance(v,list)); return [text(x) for x in v]
def matcher(v):
    if isinstance(v,str):
        v=text(v); m=re.fullmatch(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*(!?=~?|!~)\s*(.+)",v)
        need(m is not None)
        return m[1]+m[2]+("[redacted]" if secret.search(m[1]) else m[3])
    need(isinstance(v,dict)); d={normalize_key(k):x for k,x in v.items()}
    n=label(d.get("name")); out={"name":n}
    for k in ("match_type","regex"):
        if k in d: out[k]=scalar(d[k])
    if "value" in d: out["value"]="[redacted]" if secret.search(n) else text(d["value"])
    return out
def route(v):
    need(isinstance(v,dict)); out={}
    for key,x in v.items():
        k=normalize_key(key)
        if k in ("receiver","group_wait","group_interval","repeat_interval"): out[k]=text(x)
        elif k=="continue": need(type(x) is bool); out[k]=x
        elif k in ("group_by","mute_time_intervals","active_time_intervals","equal"): out[k]=names(x)
        elif k in ("matchers","source_matchers","target_matchers"):
            need(isinstance(x,list)); out[k]=[matcher(y) for y in x]
        elif k in ("match","match_re","source_match","source_match_re","target_match","target_match_re"):
            need(isinstance(x,dict)); out[k]={label(a):("[redacted]" if secret.search(a) else text(b)) for a,b in x.items()}
        elif k=="routes": need(isinstance(x,list)); out[k]=[route(y) for y in x]
        else: out.setdefault("omitted_field_names",[]).append(text(key))
    return out
def destination(v):
    if not isinstance(v,str) or not v: return "not-observed"
    if v in ("<secret>","[redacted]"): return "masked"
    try:
        h=urlsplit(v).hostname
        if not h: return "unparseable-or-template"
        if h=="localhost" or h.endswith(".localhost"): return "loopback"
        try:
            if ipaddress.ip_address(h).is_loopback: return "loopback"
        except ValueError: pass
        if h in ("example.com","example.org","example.net") or h.endswith((".example.com",".example.org",".example.net",".invalid")): return "placeholder"
        return "external"
    except Exception: return "unparseable-or-template"
def receiver(v):
    need(isinstance(v,dict)); out={"name":text(v.get("name")),"targets":[]}
    for key,x in v.items():
        if key=="name": continue
        k=normalize_key(key)
        if not k.endswith("_configs"):
            out.setdefault("omitted_field_names",[]).append(text(key)); continue
        need(isinstance(x,list))
        for item in x:
            need(isinstance(item,dict)); d={normalize_key(a):b for a,b in item.items()}
            target={"type":text(k[:-8]),"field_names":sorted(text(a) for a in item),"credential_fields":sorted(text(a) for a in d if secret.search(a))}
            if "send_resolved" in d: need(type(d["send_resolved"]) is bool); target["send_resolved"]=d["send_resolved"]
            if "channel" in d:
                channel=d["channel"]
                if isinstance(channel,str) and re.fullmatch(r"[#@]?[A-Za-z0-9_.-]{1,100}",channel): target["channel"]=channel
                else: target["channel_state"]="unresolved-template-or-unsupported"
            target["destination_class"]=destination(d.get("url",d.get("api_url",d.get("webhook_url"))))
            out["targets"].append(target)
    return out
def interval(v):
    need(isinstance(v,dict)); out={}
    for key,x in v.items():
        k=normalize_key(key)
        if k in ("name","location","start_time","end_time"): out[k]=text(x)
        elif k in ("time_intervals","times"):
            need(isinstance(x,list)); out[k]=[interval(y) for y in x]
        elif k in ("weekdays","days_of_month","months","years"):
            need(isinstance(x,list)); out[k]=[scalar(y) for y in x]
        else: out.setdefault("omitted_field_names",[]).append(text(key))
    return out
try:
    mode=sys.argv[1]; need(mode in ("yaml","crd","http-status","http-metadata"))
    raw=sys.stdin.buffer.read(LIMIT+1); need(len(raw)<=LIMIT)
    raw=raw.decode("utf-8")
    if mode.startswith("http-"):
        body,meta=raw.rsplit("\n",1); code,ct=meta.split(" ",1)
        need(re.fullmatch(r"[0-9]{3}",code) is not None)
        if code!="200":
            hint={"000":"no HTTP response; verify transport","401":"access refused; verify credentials and entitlement","403":"access refused; verify credentials and entitlement","404":"path not found; verify the configured API endpoint","429":"throttled; stop and honor the provider retry interval"}.get(code,"unexpected status; dependent checks remain blocked")
            print("Alertmanager HTTP "+code+": "+hint+". No raw response retained.",file=sys.stderr); sys.exit(2)
        if "json" not in ct.lower():
            print("Alertmanager HTTP 200: expected JSON; verify proxy or endpoint. No raw response retained.",file=sys.stderr); sys.exit(2)
        envelope=decode_json(body); need(isinstance(envelope,dict))
        bounded(envelope); cluster=envelope.get("cluster"); version=envelope.get("versionInfo")
        need(isinstance(cluster,dict) and isinstance(version,dict))
        need(isinstance(cluster.get("peers",[]),list))
        metadata={"cluster":{"status":text(cluster.get("status")),"peer_count":len(cluster.get("peers",[]))},"version":text(version.get("version"))}
        if mode=="http-metadata": print(json.dumps(metadata)); sys.exit(0)
        raw=envelope.get("config",{}).get("original"); need(isinstance(raw,str))
        config=yaml.load(raw,Loader=StrictLoader)
    elif mode=="yaml": config=yaml.load(raw,Loader=StrictLoader); metadata={}
    else:
        config=decode_json(raw); need(isinstance(config,dict) and isinstance(config.get("spec"),dict)); config=config["spec"]; metadata={}
    need(isinstance(config,dict)); bounded(config)
    config={normalize_key(k):v for k,v in config.items()}
    need(isinstance(config.get("receivers"),list) and isinstance(config.get("route"),dict))
    out={"schema":"scoutflo-alertmanager-config-projection/v1","route":route(config["route"]),"receivers":[receiver(v) for v in config["receivers"]],"credential_equality":"unassessed","metadata":metadata}
    for k in ("inhibit_rules","time_intervals","mute_time_intervals"):
        values=config.get(k,[]); need(isinstance(values,list)); out[k]=[(route(v) if k=="inhibit_rules" else interval(v)) for v in values]
    glob=config.get("global",{}); need(isinstance(glob,dict))
    out["global"]={"field_names":sorted(text(k) for k in glob)}
    if "resolve_timeout" in glob: out["global"]["resolve_timeout"]=text(glob["resolve_timeout"])
    out["omitted_field_names"]=sorted(text(k) for k in config if k not in ("route","receivers","inhibit_rules","time_intervals","mute_time_intervals","global"))
    print(json.dumps(out,sort_keys=True,allow_nan=False))
except Exception:
    print("Alertmanager projection blocked: unsupported, malformed or oversized input; no raw response retained.",file=sys.stderr)
    sys.exit(2)
' "${1:-}"
