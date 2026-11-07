#!/bin/sh
# Exact per-service reads only after an attended, evidence-backed column mapping.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}"
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Metrics blocked: invalid window' >&2; exit 1 ;; esac
MAP="$CS_OUT/raw/metrics-service-map.json"
[ -f "$MAP" ] || { echo 'Metrics blocked: confirm timestamp and service mapping first' >&2; exit 1; }
COLUMNS=$(chq "SELECT table, name, type FROM system.columns WHERE database=currentDatabase() AND table LIKE 'otel_metrics_%' ORDER BY table, name FORMAT JSON")
export COLUMNS
QUERIES=$(python3 - "$MAP" "$CS_SEG" "$RECENT_MINUTES" <<'PY'
import datetime,json,pathlib,re,sys
import os
try:
    path=pathlib.Path(sys.argv[1]); doc=json.loads(path.read_text())
    assert doc['target']==sys.argv[2]
    at=datetime.datetime.strptime(doc['observed_at'],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    now=datetime.datetime.now(datetime.timezone.utc)
    assert at.date()==now.date() and 0<=(now-at).total_seconds()<=1800
    columns=json.loads(os.environ['COLUMNS'])['data']
    seen={(r['table'],r['name']):r['type'] for r in columns}
    maps=doc['mappings']; assert isinstance(maps,list) and 0<len(maps)<=20
    queries=[]; tables=set()
    for item in maps:
        table,stamp,service=(item[k] for k in ('table','timestamp_column','service_column'))
        assert re.fullmatch(r'otel_metrics_[A-Za-z0-9_]+',table) and table not in tables
        tables.add(table)
        assert all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',v) for v in (stamp,service))
        assert seen.get((table,stamp),'').startswith('DateTime')
        assert seen.get((table,service),'') in ('String','LowCardinality(String)')
        ref=item['semantic_evidence_ref']; assert re.fullmatch(r'[A-Za-z0-9_-]+\.(json|md)',ref)
        assert (path.parent/ref).is_file() and item['service_semantics_confirmed'] is True
        queries.append(f"SELECT '{table}' AS tbl, `{service}` AS ServiceName, countIf(`{stamp}` >= now() - INTERVAL {int(sys.argv[3])} MINUTE) AS rows, max(`{stamp}`) AS latest, dateDiff('second',max(`{stamp}`),now()) AS lag_s FROM `{table}` GROUP BY `{service}` FORMAT JSON")
    print('\n'.join(queries))
except Exception:
    raise SystemExit('Metrics blocked: current target column/semantic evidence is missing or incompatible')
PY
)
printf '%s\n' "$QUERIES" | while IFS= read -r query; do chq "$query"; done
