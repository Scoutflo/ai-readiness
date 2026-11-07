#!/bin/sh
# Fixed Datadog read projections. Raw input stays in memory; output is safe metadata.
set -eu
set +x
exec python3 -c '
import datetime, hashlib, json, math, os, re, sys

def need(v):
    if not v: raise ValueError()
def pairs(xs):
    d={}
    for k,v in xs: need(k not in d); d[k]=v
    return d
secret=re.compile(r"(?i)(?:Bearer\s+\S+|[a-z][a-z0-9+.-]*://|(?:api[-_ ]?key|app[-_ ]?key|token|password|secret|authorization|credential|X-VO-Api-(?:Id|Key))\s*[:=]|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\b(?:ghp_|github_pat_|NRAK-|sk_live_|sk_test_)[A-Za-z0-9_-]+)")
def text(v,limit=512):
    if not isinstance(v,str) or len(v)>limit or any(ord(c)<32 for c in v): return None
    if secret.search(v.replace("\\/","/")): return None
    if any(s and s in v for s in (os.getenv("DATADOG_API_KEY"),os.getenv("DATADOG_APP_KEY"))): return None
    # High-entropy token-shaped words are not useful monitor names or scope identities.
    if re.search(r"(?<![a-zA-Z0-9])[A-Za-z0-9_-]{40,}(?![a-zA-Z0-9])",v): return None
    return v
def scalar(v):
    if v is None or type(v) in (bool,int): return v
    if type(v) is float: need(math.isfinite(v)); return v
    return text(v)
def identity(v):
    if type(v) is int: return v
    s=text(v); return s if s and re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}",s) else None
def strings(v):
    need(isinstance(v,list)); return [s for x in v if (s:=text(x)) is not None]
def scope_terms(v,query=False):
    # V2 downtime scope is a group-search string; monitor_tags remains an array.
    # Normalize only simple conjunctions, never interpret arbitrary search grammar.
    if query and isinstance(v,str): v=re.split(r"\s+AND\s+",v.strip())
    if not isinstance(v,list) or not v: return [],"unassessed"
    safe=[x for x in v if text(x) is not None and re.fullmatch(r"\*|[A-Za-z0-9_.-]+:[A-Za-z0-9_.$/-]+",x)]
    return safe,"observed" if len(safe)==len(v) else "omitted"
def timestamp(v):
    if v is None: return None,True
    if type(v) in (int,float): return (v,True) if math.isfinite(v) and v>=0 else (None,False)
    if not isinstance(v,str): return None,False
    try:
        d=datetime.datetime.fromisoformat(v.replace("Z","+00:00")); need(d.tzinfo is not None)
        return d.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),True
    except Exception: return None,False
def query(v,typ):
    # Only literal metric/composite/SLO grammars. Log/event bodies and arbitrary
    # quoted search strings stay omitted; dependent semantic checks remain blocked.
    s=text(v,8192)
    if s is None: return None
    if typ=="composite": return s if re.fullmatch(r"[0-9\s!&|()]+",s) else None
    if typ=="slo alert": return s if re.fullmatch(r"(?:error_budget|burn_rate)\(\"[a-fA-F0-9]{16,40}\"\)[a-zA-Z0-9_().\s><=\"-]*",s) else None
    if typ not in ("metric alert","query alert","service check"): return None
    if not re.fullmatch(r"[a-zA-Z0-9_.$:{}*,!+\-/().><=\s]+",s): return None
    # A scope term must be an ordinary identity or placeholder, never an arbitrary
    # key:value search. Keep exact literals for DD-035/036; no masked-query equivalence.
    for scope in re.findall(r"(?<!by)\{([^}]*)\}",s):
        for term in scope.split(","):
            term=term.strip()
            if term=="*" or (":" not in term and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*",term)): continue
            if not re.fullmatch(r"!?[a-zA-Z_][a-zA-Z0-9_.-]*:(?:[a-zA-Z0-9_.$*-]+)",term): return None
            if re.search(r"(?i)(?:key|token|password|secret|credential|authorization)",term.split(":",1)[0]): return None
    return s

def monitor(v):
    need(isinstance(v,dict) and identity(v.get("id")) is not None)
    typ=text(v.get("type")); rawmsg=v.get("message",""); need(isinstance(rawmsg,str))
    handles=[]; omitted=bool(re.search(r"\{\{[#^]",rawmsg))
    # Extract only standalone handles. Never interpret URL credentials/user-info as handles.
    clean=re.sub(r"(?i)[a-z][a-z0-9+.-]*://\S+"," ",rawmsg.replace("\\/","/"))
    for x in re.findall(r"(?<![\w/@])@[A-Za-z0-9._-]+(?:@[A-Za-z0-9.-]+)?",clean):
        if text(x) is None: omitted=True
        elif x not in handles: handles.append(x)
    q=query(v.get("query"),typ)
    options=v.get("options") or {}; need(isinstance(options,dict))
    out={k:scalar(v.get(k)) for k in ("id","name","priority","overall_state","overall_state_modified","created")}
    out.update(type=typ,draft_status=scalar(v.get("draft_status","published")),last_triggered_ts=scalar(v.get("overall_state_modified")),
      tags=strings(v.get("tags") or []),message=" ".join(handles),notification_handles=handles,
      message_state="handles-only",handles_complete=not omitted,query=q,query_state="observed" if q is not None else "omitted",
      omitted_fields=["message_body"]+([] if q is not None else ["query"]))
    if omitted: out["omitted_fields"].append("notification_condition_semantics")
    if len(out["tags"])!=len(v.get("tags") or []): out["omitted_fields"].append("tags")
    if out["name"] is None: out["name"]="monitor-"+str(out["id"]); out["omitted_fields"].append("name")
    for k in ("notify_no_data","require_full_window"):
        need(options.get(k) is None or type(options[k]) is bool)
    for k in ("no_data_timeframe","renotify_interval","renotify_occurrences","evaluation_delay","new_group_delay","timeout_h"):
        need(options.get(k) is None or type(options[k]) in (int,float))
    out["options"]={k:scalar(options.get(k)) for k in ("notify_no_data","no_data_timeframe","on_missing_data","renotify_interval","renotify_occurrences","evaluation_delay","new_group_delay","timeout_h","require_full_window")}
    silenced=options.get("silenced"); thresholds=options.get("thresholds") or {}
    need(isinstance(thresholds,dict))
    mute={}; mute_state="observed" if isinstance(silenced,dict) else "unassessed"
    for k,x in (silenced.items() if isinstance(silenced,dict) else []):
        scopes,state=scope_terms([k]); valid=x is None or (type(x) in (int,float) and math.isfinite(x) and x>=0)
        if state=="observed" and valid: mute[k]=x
        else: mute_state="omitted"
    out["options"]["silenced"]=mute
    out["options"]["silenced_state"]=mute_state
    need(all(v is None or type(v) in (int,float) for v in thresholds.values()))
    out["options"]["thresholds"]={k:scalar(thresholds[k]) for k in ("critical","critical_recovery","warning","warning_recovery","ok","unknown") if k in thresholds}
    if mute_state!="observed": out["omitted_fields"].append("silenced")
    return out

def project(mode,d):
    if mode=="validate": need(isinstance(d,dict) and d.get("valid") is True); return {"valid":True}
    if mode=="monitors": need(isinstance(d,list)); return [monitor(v) for v in d]
    need(isinstance(d,dict))
    if mode=="webhook":
        need(text(d.get("name")) is not None); return {"name":text(d["name"]),"destination_configuration":"exists","human_delivery":"unverified"}
    if mode=="org":
        need(isinstance(d.get("orgs"),list)); return {"org_names":[text(v.get("name")) for v in d["orgs"]]}
    if mode=="quality":
        need(isinstance(d.get("monitors"),list)); return [{"id":identity(v.get("id")),"quality_issues":strings(v.get("quality_issues") or [])} for v in d["monitors"]]
    if mode=="counts":
        n=d.get("metadata",{}).get("total_count"); need(type(n) is int and n>=0); return {"count":n}
    if mode=="downtimes":
        need(isinstance(d.get("data"),list)); out=[]
        for v in d["data"]:
            a=v["attributes"]; need(isinstance(a,dict))
            schedule=a.get("schedule"); ident=a.get("monitor_identifier")
            schedule=schedule if isinstance(schedule,dict) else {}; ident=ident if isinstance(ident,dict) else {}
            scope,scope_state=scope_terms(a.get("scope"),query=True)
            tags,tag_state=scope_terms(ident.get("monitor_tags"))
            mid=identity(ident.get("monitor_id"))
            identifier_state="observed" if ((mid is not None and not ident.get("monitor_tags")) or (mid is None and "monitor_id" not in ident and tag_state=="observed")) else "unassessed"
            start,ok_start=timestamp(schedule.get("start")); end,ok_end=timestamp(schedule.get("end")); created,ok_created=timestamp(a.get("created"))
            schedule_state="observed" if "start" in schedule and "end" in schedule and ok_start and ok_end and not schedule.get("recurrences") else "unassessed"
            annotation=a.get("message")
            words=os.getenv("SCOUTFLO_DATADOG_TEMPORARY_WORDS","test|temp|safe to delete|debug").split("|")
            valid_words=bool(words) and all(re.fullmatch(r"[A-Za-z][A-Za-z -]{0,63}",w) and text(w) is not None for w in words)
            intent={"predicate":"literal-substring-any-case-insensitive/v1","terms":words if valid_words else [],"state":"observed" if valid_words and isinstance(annotation,str) else "unassessed","matched":None}
            if intent["state"]=="observed": intent["matched"]=any(w.lower() in annotation.lower() for w in words)
            out.append({"id":identity(v.get("id")),"scope":scope,"scope_state":scope_state,"status":text(a.get("status")),"start":start,"end":end,"schedule_state":schedule_state,"recurrences":None if not schedule.get("recurrences") else "present-unassessed","monitor_identifier":{"monitor_id":mid,"monitor_tags":tags},"identifier_state":identifier_state,"temporary_intent":intent,"created":created,"created_state":"observed" if ok_created and created is not None else "unassessed"})
        return out
    if mode=="slos":
        need(isinstance(d.get("data"),list)); return [{"id":identity(v.get("id")),"name":text(v.get("name")),"type":text(v.get("type")),"monitor_ids":[identity(x) for x in v.get("monitor_ids",[])]} for v in d["data"]]
    if mode=="events":
        need(isinstance(d.get("events"),list)); return [{k:scalar(v.get(k)) for k in ("id","monitor_id","alert_type","date_happened")} for v in d["events"]]
    if mode=="synthetics":
        need(isinstance(d.get("tests"),list)); return [{k:scalar(v.get(k)) for k in ("public_id","status","monitor_id")} for v in d["tests"]]
    if mode=="events-v2": need(isinstance(d.get("data"),list)); return {"count":len(d["data"]),"complete":not bool(d.get("meta",{}).get("page",{}).get("after"))}
    if mode=="estimated-cost":
        need(isinstance(d.get("data"),list)); return [{"date":scalar(v.get("attributes",{}).get("date")),"total_cost":scalar(v.get("attributes",{}).get("total_cost")),"charges":[{k:scalar(c.get(k)) for k in ("product_name","charge_type","cost")} for c in v.get("attributes",{}).get("charges",[])]} for v in d["data"]]
    if mode=="top-metrics":
        need(isinstance(d.get("usage"),list)); return [{"metric_name":text(v.get("metric_name")),"avg_metric_hour":scalar(v.get("avg_metric_hour"))} for v in d["usage"]]
    if mode=="notification-rules":
        need(isinstance(d.get("data"),list)); out=[]
        for v in d["data"]:
            a=v.get("attributes") or {}; scope=a.get("filter",{})
            # Filter language varies by API version. Presence is evidence; unsupported
            # filter semantics cannot exonerate an inline notification gap.
            out.append({"id":identity(v.get("id")),"filter_state":"observed" if isinstance(scope,dict) and isinstance(scope.get("tags"),list) else "present-unassessed","filter_tags":strings(scope["tags"]) if isinstance(scope,dict) and isinstance(scope.get("tags"),list) else [],"recipients":strings(a.get("recipients") or [])})
        return out
    if mode=="policies": need(isinstance(d.get("data"),list)); return [{"id":identity(v.get("id")),"policy_state":"present-unassessed"} for v in d["data"]]
    if mode=="usage":
        need(isinstance(d.get("usage"),list)); return [{k:scalar(v.get(k)) for k in ("date","hour","num_custom_timeseries","num_hosts","num_containers") if k in v} for v in d["usage"]]
    if mode=="dashboards":
        need(isinstance(d.get("dashboards"),list)); return [{k:scalar(v.get(k)) for k in ("id","title","modified_at","is_read_only")} for v in d["dashboards"]]
    raise ValueError()
try:
    mode=sys.argv[1]; raw=sys.stdin.buffer.read(8388609); need(len(raw)<=8388608)
    body,meta=raw.decode("utf-8").rsplit("\n",1); code,ct=meta.split(" ",1)
    need(re.fullmatch(r"[0-9]{3}",code) is not None)
    if code!="200":
        print("Datadog HTTP "+code+": dependent checks blocked; no raw response retained.",file=sys.stderr); sys.exit(2)
    need("json" in ct.lower()); d=json.loads(body,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
    out=project(mode,d)
    print(json.dumps(out,sort_keys=True,allow_nan=False))
except Exception:
    print("Datadog projection blocked: unsupported, malformed or oversized response; no raw response retained.",file=sys.stderr); sys.exit(2)
' "${1:?projection mode required}"
