#!/bin/sh
# DD-019 requires evidence about the full evaluated expression, not its metric name.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json
python3 - "$RAW_DIR/monitors.json" "${SCOUTFLO_DATADOG_NONNEGATIVE_EVIDENCE:-}" <<'PY'
import hashlib,json,pathlib,re,sys
monitors=json.loads(pathlib.Path(sys.argv[1]).read_text())
proof=json.loads(pathlib.Path(sys.argv[2]).read_text()) if sys.argv[2] else []
assert isinstance(proof,list)
out=[]
for m in monitors:
    q=m.get('query'); match=re.search(r'(>=|>)\s*(-?[0-9]+(?:\.[0-9]+)?)\s*$',q or '')
    if m.get('query_state')!='observed' or not match: continue
    op,limit=match.groups(); limit=float(limit)
    # Strictly greater than zero can recover at zero. It is never this tautology.
    if limit>0 or (limit==0 and op=='>'): continue
    digest=hashlib.sha256(q.encode()).hexdigest()
    known=[p for p in proof if str(p.get('monitor_id'))==str(m['id']) and p.get('query_sha256')==digest and p.get('lower_bound')==0 and p.get('evidence_ref') and p.get('declared_by')]
    out.append({'id':m['id'],'assessment':'fail' if known else 'blocked','reason':'comparison true for every value in the evidenced nonnegative domain' if known else 'evaluated-expression lower bound not evidenced; metric-name hints cannot prove it','comparator':op,'threshold':limit,'query_sha256':digest})
print(json.dumps(out,sort_keys=True))
PY
