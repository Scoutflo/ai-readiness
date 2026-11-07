#!/bin/sh
# Bind safe evidence to this target/site/date and reject stale or edited files.
set -eu
exec python3 -c '
import datetime, hashlib, json, os, pathlib, sys
mode,path,target,site,day=sys.argv[1:]
p=pathlib.Path(path); meta=p.with_name(p.name+".capture.json")
try:
    generation=os.environ["DD_CREDENTIAL_GENERATION"]; assert len(generation)==64
    data=p.read_bytes(); value=json.loads(data); digest=hashlib.sha256(data).hexdigest()
    if mode=="write":
        out={"schema":"scoutflo-datadog-capture/v1","source_target":target,"source_site":site,"run_date":day,"credential_generation":generation,"observed_at":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),"evidence_sha256":digest}
        meta.write_text(json.dumps(out,sort_keys=True)+"\n"); meta.chmod(0o600)
    else:
        m=json.loads(meta.read_text())
        assert m["schema"]=="scoutflo-datadog-capture/v1" and m["source_target"]==target and m["source_site"]==site and m["run_date"]==day and m["evidence_sha256"]==digest and m["credential_generation"]==generation
except Exception:
    print("Datadog evidence missing, stale, changed or from a different target; repeat its owning read.",file=sys.stderr); sys.exit(2)
' "${1:?mode}" "${2:?file}" "${3:?target}" "${4:?site}" "${5:?date}"
