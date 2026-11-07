#!/bin/sh
# Update local history; disappearance from a partial collection is not resolution.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
python3 - "$TARGET_DIR" "$RUN_DATE" "$DD_SEG" <<'PY'
import json,pathlib,re,sys
p,day,target=pathlib.Path(sys.argv[1]),sys.argv[2],sys.argv[3]
current=json.loads((p/day/'findings.json').read_text()); assert current['target']==target
older=sorted(x for x in p.iterdir() if x.is_dir() and re.fullmatch(r'\d{4}-\d{2}-\d{2}',x.name) and x.name<day and (x/'findings.json').exists())
previous=json.loads((older[-1]/'findings.json').read_text()) if older else {'findings':[]}
assert previous.get('target',target)==target
passed={v['id'] for v in current.get('checks',[]) if v.get('result')=='pass'}
resolved={v['id'] for v in previous['findings'] if v['id'] in passed}
counts={}
for v in current['findings']: counts[v['lifecycle']]=counts.get(v['lifecycle'],0)+1
counts['resolved']=len(resolved)
s=current['score']
line={'run_date':day,'skill':'audit-datadog','overall':s['overall'],'state':s['state'],'scoring_model':s['scoring_model'],'check_set':s['check_set'],'assessment_coverage_percent':s['assessment']['coverage_percent'],'gate':s['gate'],'end_to_end':s['end_to_end'],'severity_counts':current['severity_counts'],'lifecycle_counts':counts}
h=p/'history.jsonl'; rows=[json.loads(x) for x in h.read_text().splitlines() if x.strip()] if h.exists() else []
rows=[x for x in rows if x['run_date']!=day]+[line]; rows.sort(key=lambda x:x['run_date'])
temp=h.with_suffix('.tmp'); temp.write_text(''.join(json.dumps(x,sort_keys=True)+'\n' for x in rows)); temp.chmod(0o600); temp.replace(h)
print('history.jsonl updated; resolved readiness checks: '+str(len(resolved)))
PY
