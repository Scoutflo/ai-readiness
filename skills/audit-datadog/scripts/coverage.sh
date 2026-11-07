#!/bin/sh
# DD-002/DD-033 local join. This reports source eligibility, never human delivery.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json monitor-quality.json downtimes.json
DD_INTENT="${SCOUTFLO_DATADOG_COVERAGE_INTENT:?set to the explicit service/heartbeat declaration JSON file}"
python3 - "$RAW_DIR" "$DD_INTENT" <<'PY'
import datetime, json, pathlib, sys
raw,intent_path=sys.argv[1:]; p=pathlib.Path(raw)
try:
    m=json.loads((p/'monitors.json').read_text()); quality=json.loads((p/'monitor-quality.json').read_text()); downs=json.loads((p/'downtimes.json').read_text()); intent=json.loads(pathlib.Path(intent_path).read_text())
    assert intent.get('declared_by') and intent.get('evidence_ref') and isinstance(intent.get('critical_services'),list)
    heartbeat=intent.get('missing_data_required_monitor_ids',[]); assert isinstance(heartbeat,list)
    bad={str(v['id']) for v in quality if 'broken_at_handle' in v['quality_issues']}
    now=datetime.datetime.now(datetime.timezone.utc).timestamp()
    def epoch(v):
        if v is None: return None
        if isinstance(v,(int,float)): return v
        return datetime.datetime.fromisoformat(v.replace('Z','+00:00')).timestamp()
    def suppressed(v,service):
        unknown=v["options"].get("silenced_state")!="observed"
        for scope,until in v['options']['silenced'].items():
            if until not in (None,0) and epoch(until)<=now: continue
            if scope=='*': return True,unknown
            # A muted group does not suppress every group in the monitor.
            unknown=True
        for d in downs:
            if d['status']!='active':
                if d['status'] not in ('scheduled','canceled','ended'): unknown=True
                continue
            if any(d.get(k)!='observed' for k in ('schedule_state','scope_state','identifier_state')):
                unknown=True; continue
            if d['end'] is not None and epoch(d['end'])<=now: continue
            if d['start'] is not None and epoch(d['start'])>now: continue
            ids=d.get('monitor_identifier',{}); did=ids.get('monitor_id'); tags=ids.get('monitor_tags',[])
            matches=(did is not None and str(did)==str(v['id'])) or (did is None and (tags==['*'] or (tags and all(t in v['tags'] for t in tags))))
            if not matches: continue
            if d['scope']==['*']: return True,unknown
            # Downtime scope selects monitor groups, not definition-level tags.
            unknown=True
        return False,unknown
    rows=[]
    for service in intent['critical_services']:
        assert isinstance(service,str) and service and all(c.isalnum() or c in '_.-' for c in service)
        matched=[v for v in m if 'service:'+service in v['tags']]; eligible=[]; unknown=[]; rejected=[]
        for v in matched:
            suppress,ambiguous=suppressed(v,service)
            handles=[h for h in v['notification_handles'] if not __import__('re').search(r'(?i)^@(your|example|replace-?me|team-?name).*handle$|^@handle$',h)]
            reasons=[]
            if v['draft_status']!='published': reasons.append('not-published')
            if not handles: reasons.append('no-usable-inline-handle; notification-rule routing still needs assessment')
            if str(v['id']) in bad: reasons.append('vendor-broken-handle')
            if suppress: reasons.append('active-suppression')
            if str(v['id']) in {str(x) for x in heartbeat} and v['options']['notify_no_data'] is not True and v['options']['on_missing_data'] not in ('show_and_notify_no_data',): reasons.append('declared-missing-data-notification-required')
            if reasons: rejected.append({'id':v['id'],'reasons':reasons})
            elif ambiguous or not v['handles_complete'] or 'tags' in v['omitted_fields'] or 'silenced' in v['omitted_fields']: unknown.append(v['id'])
            else: eligible.append(v['id'])
        rows.append({'service':service,'inventory_monitors':len(matched),'source_eligible_monitors':len(eligible),'source_eligible_ids':eligible,'source_eligibility_unknown_ids':unknown,'excluded':rejected,'unverified_destination_monitors':len(eligible),'human_delivery':'unverified','end_to_end':False,'assessment':'blocked' if eligible or unknown else 'source-gap-needs-rule-routing-check'})
    print(json.dumps(rows,sort_keys=True,indent=2))
except Exception:
    print('Datadog coverage blocked: invalid declaration or unsupported evidence; no delivery inferred.',file=sys.stderr); sys.exit(2)
PY
