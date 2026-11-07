#!/bin/sh
# Package source-read metadata. An @handle never establishes a protected route key.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json
umask 077
python3 - "$RAW_DIR" "$DD_SEG" "$DD_SITE" <<'PY'
import hashlib, json, pathlib, re, sys
raw,target,site=sys.argv[1:]; p=pathlib.Path(raw)
m=json.loads((p/'monitors.json.capture.json').read_text()); monitors=json.loads((p/'monitors.json').read_text())
records=[]
for v in monitors:
    handles=v['notification_handles']
    if not any(x.lower().startswith(('@victorops-','@splunk-oncall-')) for x in handles): continue
    safe_handles=[x for x in handles if re.fullmatch(r'@[A-Za-z0-9][A-Za-z0-9_.-]{0,159}',x)]
    services=[x for x in v['tags'] if re.fullmatch(r'service:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',x)]
    complete=v['handles_complete'] and len(handles)==len(safe_handles) and v['type'] is not None
    # One independently mappable source path per real paging handle; no first-handle collapse.
    for handle in sorted(set(x for x in safe_handles if x.lower().startswith(('@victorops-','@splunk-oncall-')))):
        definition={'monitor_id':str(v['id']),'monitor_type':v['type'] or 'unknown','notification_handles':[handle],'enabled':v['draft_status']=='published','service_tags':services,'source_site':site}
        route_id=hashlib.sha256(handle.encode()).hexdigest()[:16]
        records.append({'record_id':'monitor-'+str(v['id'])+'-route-'+route_id,'source_id':str(v['id']),'route_env':None,'route_verification':'candidate' if complete else 'blocked','definition':definition})
out={'schema':'scoutflo-alert-source-evidence/v1','producer':'audit-datadog','source_provider':'datadog','source_target':target,'observed_at':m['observed_at'],'verification':{'kind':'api-read','status':'verified','evidence_ref':'source-routing-capture.json'},'records':records}
receipt={'schema':'scoutflo-alert-source-capture/v1','producer':'audit-datadog','source_provider':'datadog','source_target':target,'observed_at':m['observed_at'],'verification':{'kind':'api-read','status':'verified'},'records_sha256':hashlib.sha256(json.dumps(records,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()).hexdigest()}
(p/'source-routing-capture.json').write_text(json.dumps(receipt,sort_keys=True)+'\n')
(p/'source-routing-capture.json').chmod(0o600)
(p/'source-routing-evidence.json').write_text(json.dumps(out,sort_keys=True,indent=2)+'\n')
(p/'source-routing-evidence.json').chmod(0o600)
PY
dd_stamp source-routing-evidence.json
