#!/usr/bin/env python3
"""Bounded HyperDX configuration read recipe. Never writes provider response bodies."""
import datetime as dt
import hashlib
import http.cookiejar
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import signal
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 4 * 1024 * 1024
PAGE_SIZE = 100
MAX_PAGES = 50
MAX_ROWS = PAGE_SIZE * MAX_PAGES
SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
SECRET_ID = re.compile(r"(?i)(?:[a-z][a-z0-9+.-]*://|(?:^|[._:-])(?:api[-_]?key|app[-_]?key|token|password|secret|authorization|credential|X-VO-Api-(?:Id|Key))[:=]|(?:^|[._:-])(?:ghp_|github_pat_|NRAK-|sk_live_|sk_test_)|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b)")

class Blocked(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def unique_object(pairs):
    obj = {}
    for k, v in pairs:
        if k in obj:
            raise Blocked('duplicate-json-key')
        obj[k] = v
    return obj

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode()

def ident(value):
    secrets=[os.environ.get(k,'') for k in ('HDX_CAPTURE_KEY','HDX_CAPTURE_PASSWORD')]
    if isinstance(value,str) and any(len(v)>=4 and v in value for v in secrets): return None
    return value if isinstance(value, str) and SAFE_ID.fullmatch(value) and not SECRET_ID.search(value) else None

def reference(value, present):
    if not present: return None, 'missing'
    if value is None or value=='': return None, 'empty'
    if not isinstance(value,str): return None, 'malformed'
    safe=ident(value)
    return (safe,'observed') if safe is not None else (None,'omitted')

def object_id(obj):
    if not isinstance(obj, dict):
        raise Blocked('unexpected-object-shape')
    a, b = obj.get('id'), obj.get('_id')
    if a is not None and b is not None and a != b:
        raise Blocked('conflicting-object-id')
    value = ident(a if a is not None else b)
    if value is None:
        raise Blocked('missing-or-unsafe-object-id')
    return value

def destination(value):
    """Keep classification only, never URL, path, userinfo, query or raw host."""
    if not isinstance(value, str) or not value:
        return {'destination_class': 'unknown', 'destination_kind': 'unknown'}
    try:
        url = urllib.parse.urlsplit(value)
        host = (url.hostname or '').lower().rstrip('.')
        if url.scheme not in ('http', 'https') or not host:
            raise ValueError()
        if '*' in host or '<' in host or '[' in host:
            cls = 'masked'
        elif host in ('example.com', 'example.org', 'example.net', 'webhook.site') or host.endswith(('.example.com', '.example.org', '.example.net', '.invalid', '.test')):
            cls = 'placeholder'
        elif host == 'localhost' or host.endswith('.localhost'):
            cls = 'loopback'
        else:
            try:
                addr = ipaddress.ip_address(host)
                cls = 'loopback' if addr.is_loopback else 'private' if not addr.is_global else 'public'
            except ValueError:
                cls = 'private' if host.endswith(('.local', '.internal')) else 'public'
        kind = 'oncall-inbound' if host == 'alert.victorops.com' else 'intermediary'
        return {'destination_class': cls, 'destination_kind': kind}
    except (ValueError, TypeError):
        return {'destination_class': 'unknown', 'destination_kind': 'unknown'}

def project(resource, row):
    out = {'id': object_id(row)}
    if resource == 'webhooks':
        out.update(destination(row.get('url')))
        out['service'] = row.get('service') if row.get('service') in ('slack','generic','incidentio') else 'unknown'
    elif resource == 'connections':
        out.update(destination(row.get('host')))
    elif resource == 'sources':
        out.update(connection_id=ident(row.get('connection')), kind=row.get('kind') if row.get('kind') in ('log','trace','metric','session','promql') else 'unknown')
    elif resource == 'dashboards':
        tiles = row.get('tiles')
        if not isinstance(tiles, list) or len(tiles) > MAX_ROWS:
            raise Blocked('invalid-dashboard-tiles')
        out['tiles'] = []
        for tile in tiles:
            if not isinstance(tile,dict) or not isinstance(tile.get('config'),dict):
                raise Blocked('unsupported-dashboard-tile')
            out['tiles'].append({'id':object_id(tile),'source_id':ident(tile['config'].get('sourceId'))})
    elif resource == 'alerts':
        state = row.get('state')
        out['enabled'] = False if state == 'DISABLED' else True if state in ('ALERT','OK','INSUFFICIENT_DATA','PENDING') else None
        out['source_id'] = ident(row.get('sourceId'))
        out['dashboard_id'] = ident(row.get('dashboardId'))
        out['tile_id'] = ident(row.get('tileId'))
        out['source_kind'] = row.get('source') if row.get('source') in ('tile','saved_search','inline') else 'unknown'
        # Current API's channel mirrors channels[0]; do not double-count it.
        channels = row.get('channels') if 'channels' in row else [row.get('channel', {})]
        if not isinstance(channels, list) or not 1 <= len(channels) <= 10:
            raise Blocked('invalid-alert-channels')
        out['channels'] = []
        for channel in channels:
            if not isinstance(channel, dict):
                raise Blocked('invalid-alert-channel')
            receiver_id,receiver_state=reference(channel.get('webhookId'),'webhookId' in channel)
            out['channels'].append({'channel_type': 'webhook' if channel.get('type') == 'webhook' else 'unknown', 'receiver_id':receiver_id,'receiver_id_state':receiver_state})
    return out

class Client:
    def __init__(self, base, key='', email='', password=''):
        parsed = urllib.parse.urlsplit(base)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise Blocked('unsafe-configured-api-url')
        self.base = base.rstrip('/')
        self.key, self.email, self.password = key, email, password
        self.mode, self.prefix = None, None
        self.opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.requests = 0
        self.started = time.monotonic()

    def request(self, path, login=False):
        self.requests += 1
        if self.requests > MAX_PAGES * 2 + 10 or (time.monotonic()-self.started) > 240:
            raise Blocked('collection-budget-exhausted')
        headers = {'Accept': 'application/json'}
        data = None
        if login:
            headers['Content-Type'] = 'application/json'
            data = canonical({'email': self.email, 'password': self.password})
        elif self.mode == 'key':
            headers['Authorization'] = 'Bearer ' + self.key
        req = urllib.request.Request(self.base+path, headers=headers, data=data, method='POST' if login else 'GET')
        def timeout_handler(signum, frame):
            raise Blocked('request-time-limit')
        previous=signal.signal(signal.SIGALRM,timeout_handler)
        signal.setitimer(signal.ITIMER_REAL,min(20,max(0.001,240-(time.monotonic()-self.started))))
        try:
            with self.opener.open(req, timeout=20) as resp:
                if login:
                    return None
                if resp.headers.get_content_type() != 'application/json':
                    raise Blocked('non-json-response')
                raw = resp.read(MAX_BYTES+1)
                if len(raw) > MAX_BYTES:
                    raise Blocked('response-size-limit')
                return json.loads(raw, object_pairs_hook=unique_object, parse_constant=lambda _: (_ for _ in ()).throw(Blocked('nonfinite-json')))
        except urllib.error.HTTPError as exc:
            if login and exc.code == 303:
                return None
            raise Blocked('http-'+str(exc.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Blocked('transport-error') from None
        except (UnicodeError, ValueError):
            raise Blocked('invalid-json') from None
        finally:
            signal.setitimer(signal.ITIMER_REAL,0)
            signal.signal(signal.SIGALRM,previous)

    def select(self):
        if os.environ.get('HDX_CAPTURE_MODE') == 'key' and not self.key:
            raise Blocked('selected-api-key-unset')
        if self.key:
            self.mode = 'key'
            for prefix in ('/api/v2','/api/api/v2'):
                try:
                    first = self.request(prefix+'/alerts?limit=100&offset=0')
                    if not isinstance(first,dict) or not isinstance(first.get('data'),list):
                        raise Blocked('unexpected-list-shape')
                    self.prefix = prefix
                    return first
                except Blocked as exc:
                    # Only path/HTML mismatches justify the documented proxy path.
                    if str(exc) not in ('http-404','non-json-response'):
                        raise
            raise Blocked('external-v2-path-unavailable')
        if self.email and self.password:
            self.mode, self.prefix = 'session', '/api'
            self.request('/api/login/password', login=True)
            return self.request('/api/alerts')
        raise Blocked('missing-read-credential')

    def collect(self, resource, first=None):
        result = {'status':'blocked','scope':'subset','items':[], 'reason':'not-read', 'total':None}
        seen, total = set(), None
        try:
            if self.mode == 'session':
                paths = [self.prefix+'/webhooks?service='+s for s in ('slack','generic','incidentio')] if resource == 'webhooks' else [self.prefix+'/'+resource]
                for path in paths:
                    body = first if first is not None else self.request(path)
                    first = None
                    # Legacy confirmed session lists are bare arrays or data arrays.
                    rows = body if isinstance(body,list) else body.get('data') if isinstance(body,dict) else None
                    if not isinstance(rows,list):
                        raise Blocked('unexpected-list-shape')
                    if len(rows) >= MAX_ROWS:
                        raise Blocked('row-limit')
                    for row in rows:
                        item = project(resource,row)
                        if item['id'] in seen: raise Blocked('duplicate-object-id')
                        seen.add(item['id']);result['items'].append(item)
                # No server total: positive ID matches only, absence stays unknown.
                result.update(status='partial',scope='subset',reason='legacy-list-has-no-total')
            else:
                paged = resource in ('alerts','webhooks')
                for page in range(MAX_PAGES if paged else 1):
                    offset = len(result['items'])
                    path = self.prefix+'/'+resource+(f'?limit={PAGE_SIZE}&offset={offset}' if paged else '')
                    body = first if first is not None else self.request(path)
                    first = None
                    if not isinstance(body,dict) or not isinstance(body.get('data'),list):
                        raise Blocked('unexpected-list-shape')
                    rows, meta = body['data'],body.get('meta',{})
                    if not isinstance(meta,dict) or len(rows)> (PAGE_SIZE if paged else MAX_ROWS):
                        raise Blocked('invalid-list-metadata')
                    if paged:
                        now = meta.get('total')
                        if type(now) is not int or now<0 or now>MAX_ROWS or meta.get('offset')!=offset or meta.get('limit')!=PAGE_SIZE:
                            raise Blocked('invalid-pagination')
                        if total is not None and now!=total: raise Blocked('collection-changed-during-pagination')
                        total=now; result['total']=total
                    for row in rows:
                        item=project(resource,row)
                        if item['id'] in seen: raise Blocked('duplicate-object-id')
                        seen.add(item['id']);result['items'].append(item)
                    if not paged:
                        if meta.get('skipped') not in (None,0) or meta.get('skippedIds'):
                            result.update(status='partial',reason='provider-omitted-objects')
                        else:
                            result.update(status='partial',reason='list-has-no-server-total')
                        break
                    if len(seen)>total: raise Blocked('count-exceeds-total')
                    if len(seen)==total:
                        result.update(status='complete',scope='target',reason='paged-total-reconciled'); break
                    if not rows: raise Blocked('premature-empty-page')
                else:
                    raise Blocked('page-limit')
        except Blocked as exc:
            result.update(status='blocked',scope='subset',reason=str(exc))
        return result

def joins(resources):
    def index(kind):
        return {r['id']:r for r in resources[kind]['items']}
    wh, sources, connections, dashboards = (index(k) for k in ('webhooks','sources','connections','dashboards'))
    records=[]
    for alert in resources['alerts']['items']:
        sid=alert['source_id']
        if not sid and alert['source_kind']=='tile':
            tiles=dashboards.get(alert['dashboard_id'],{}).get('tiles',[])
            found=[t['source_id'] for t in tiles if t['id']==alert['tile_id']]
            sid=found[0] if len(found)==1 else None
        cid=sources.get(sid,{}).get('connection_id')
        for number,ch in enumerate(alert['channels']):
            wid=ch['receiver_id']; receiver=wh.get(wid)
            if ch['channel_type']=='unknown' or ch.get('receiver_id_state') in ('omitted','malformed'): resolution='blocked'
            elif not wid: resolution='missing-id'
            elif resources['webhooks']['status']=='blocked': resolution='blocked'
            elif receiver: resolution='resolved'
            elif resources['webhooks']['status']=='complete': resolution='absent'
            else: resolution='blocked'
            definition={'alert_id':alert['id'],'source_id':sid,'connection_id':cid,'enabled':alert['enabled'],'channel_type':ch['channel_type'],'receiver_id':wid,'receiver_resolution':resolution, 'destination_class':receiver['destination_class'] if receiver else 'unknown','destination_kind':receiver['destination_kind'] if receiver else 'unknown'}
            records.append({'record_id':alert['id']+'-channel-'+str(number),'source_id':alert['id'],'route_env':None,'route_verification':'candidate' if resolution=='resolved' and resources['alerts']['status']!='blocked' else 'blocked','definition':definition})
    source_joins=[]
    for source in resources['sources']['items']:
        cid=source['connection_id']
        status='resolved' if cid in connections and resources['connections']['status']!='blocked' and resources['sources']['status']!='blocked' else 'blocked'
        source_joins.append({'source_id':source['id'],'connection_id':cid,'resolution':status,'data_freshness':'unverified','data_binding':'attended-exact-endpoint-database-table-proof-required'})
    return records,source_joins

def atomic(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent,delete=False,mode='wb') as f:
        f.write(canonical(value)+b'\n');tmp=Path(f.name)
    os.chmod(tmp,0o600);tmp.replace(path)

def main():
    out=Path(sys.argv[1]);target=sys.argv[2]
    if not re.fullmatch(r'clickstack(?:/[a-zA-Z0-9_-]+)?',target): raise Blocked('invalid-target-segment')
    probe = len(sys.argv) == 4 and sys.argv[3] == '--probe'
    sizing = len(sys.argv) == 4 and sys.argv[3] == '--size'
    if len(sys.argv) > 3 and not (probe or sizing): raise Blocked('invalid-mode')
    if sizing:
        # One page per resource, before detailed collection. No incomplete count is zero.
        counts = {}
        reason = 'unreadable-counts'
        try:
            client=Client(os.environ['HDX_CAPTURE_URL'],os.environ.get('HDX_CAPTURE_KEY',''),os.environ.get('HDX_CAPTURE_EMAIL',''),os.environ.get('HDX_CAPTURE_PASSWORD',''))
            first=client.select()
            for kind in ('alerts','dashboards','sources'):
                body=first if kind=='alerts' else client.request(client.prefix+'/'+kind)
                rows=body if isinstance(body,list) else body.get('data') if isinstance(body,dict) else None
                if not isinstance(rows,list) or len(rows)>MAX_ROWS: raise Blocked('invalid-size-shape')
                for row in rows: project(kind,row)
                meta=body.get('meta',{}) if isinstance(body,dict) else {}
                total=meta.get('total') if isinstance(meta,dict) else None
                if type(total) is int and len(rows)<=total<=MAX_ROWS: counts[kind]=total
                else: counts[kind]=len(rows)
            reason='bounded-discovery-lower-bound-services-and-unlisted-objects-unknown'
        except Blocked:
            pass
        out.mkdir(parents=True,exist_ok=True)
        result={'schema':'scoutflo-clickstack-sizing/v1','target':target,'observed_at':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),'counts':counts,'objects_lower_bound':sum(counts.values()),'complete':False,'path':'large','reason':reason}
        atomic(out/'estate-sizing.json',result)
        print('Estate sizing: '+str(result['objects_lower_bound'])+' observed objects; unknown remainder, conservative large path')
        return 0
    if probe:
        client=Client(os.environ['HDX_CAPTURE_URL'],os.environ.get('HDX_CAPTURE_KEY',''),os.environ.get('HDX_CAPTURE_EMAIL',''),os.environ.get('HDX_CAPTURE_PASSWORD',''))
        first=client.select()
        rows=first if isinstance(first,list) else first.get('data') if isinstance(first,dict) else None
        if not isinstance(rows,list): raise Blocked('unexpected-list-shape')
        for row in rows: project('alerts',row)
        print('HyperDX authenticated JSON read verified ('+client.mode+'); delivery unverified')
        return 0
    out.mkdir(parents=True,exist_ok=True)
    stamp=dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    resources={k:{'status':'blocked','scope':'subset','reason':'authentication-unavailable','total':None,'items':[]} for k in ('alerts','webhooks','sources','connections','dashboards')}
    mode='unavailable';request_count=0
    try:
        client=Client(os.environ['HDX_CAPTURE_URL'],os.environ.get('HDX_CAPTURE_KEY',''),os.environ.get('HDX_CAPTURE_EMAIL',''),os.environ.get('HDX_CAPTURE_PASSWORD',''))
        first=client.select();mode=client.mode
        for kind in resources:
            resources[kind]=client.collect(kind,first if kind=='alerts' else None)
        request_count=client.requests
    except Blocked as exc:
        for kind in resources: resources[kind]['reason']=str(exc)
    records,source_joins=joins(resources)
    verified=resources['alerts']['status']!='blocked'
    verification={'kind':'api-read','status':'verified' if verified else 'blocked'}
    capture={'schema':'scoutflo-alert-source-capture/v1','producer':'audit-clickstack','source_provider':'clickstack','source_target':target,'observed_at':stamp,'verification':verification,'records_sha256':hashlib.sha256(canonical(records)).hexdigest()}
    packet={**{k:capture[k] for k in ('producer','source_provider','source_target','observed_at')},'schema':'scoutflo-alert-source-evidence/v1','verification':{**verification,'evidence_ref':'alert-source-capture.json'},'records':records}
    projection={'schema':'scoutflo-hyperdx-configuration/v1','target':target,'observed_at':stamp,'mode':mode,'requests':request_count,'resources':resources,'source_connections':source_joins,'delivery':'unverified','history':'not-collected'}
    # Fresh blocked output replaces stale success on every attempted collection.
    atomic(out/'hyperdx-configuration.json',projection)
    atomic(out/'alert-source-capture.json',capture)
    atomic(out/'alert-source-evidence.json',packet)
    print('HyperDX safe projection: '+str(len(resources['alerts']['items']))+' observed alerts; delivery unverified')
    return 1 if any(r['status']=='blocked' for r in resources.values()) else 0

if __name__=='__main__':
    try: sys.exit(main())
    except Exception:
        print('HyperDX blocked: invalid local input or projection failure; no raw response logged',file=sys.stderr)
        sys.exit(1)
