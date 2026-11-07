#!/bin/sh
# Source and prepare once in each aggregation shell. Returns no unverified files.
sf_run_prepare() {
  SF_RUN_ROOT=$1; SF_RUN_DATE=$2
  if [ ! -e "$SF_RUN_ROOT/run-plan.json" ] && [ ! -L "$SF_RUN_ROOT/run-plan.json" ]; then
    SF_RUN_DOCUMENT='{"mode":"legacy"}'; SF_RUN_MODE=legacy; return 0
  fi
  SF_RUN_DOCUMENT=$(python3 "${SF_RUN_SCRIPT_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/report-standard/run-selection.py" snapshot "$SF_RUN_ROOT" "$SF_RUN_DATE") || return 1
  SF_RUN_MODE=$(printf '%s' "$SF_RUN_DOCUMENT" | jq -r .mode)
}
sf_run_file() {
  sf_path=$1
  [ "$SF_RUN_MODE" = selected ] || return 0
  sf_relative=${sf_path#"$SF_RUN_ROOT"/}
  [ "$sf_relative" != "$sf_path" ] || return 1
  sf_name=${sf_relative##*/}; sf_target=${sf_relative%/"$SF_RUN_DATE"/"$sf_name"}
  [ "$sf_target" != "$sf_relative" ] || return 1
  printf '%s' "$SF_RUN_DOCUMENT" | jq -e --arg t "$sf_target" --arg n "$sf_name" '
    (.completed_targets|index($t))!=null and .completion_receipts[$t].artifacts[$n]!=null' >/dev/null || return 1
  sf_expected=$(printf '%s' "$SF_RUN_DOCUMENT" | jq -r --arg t "$sf_target" --arg n "$sf_name" '.completion_receipts[$t].artifacts[$n]')
  python3 "${SF_RUN_SCRIPT_ROOT:-${CLAUDE_PLUGIN_ROOT:-.}}/report-standard/run-selection.py" verify-file "$SF_RUN_ROOT" "$SF_RUN_DATE" "$sf_path" "$sf_expected" || exit 1
}

# A saved roll-up is valid for a selected run only while all input generations match.
sf_run_aggregate_file() {
  [ "$SF_RUN_MODE" = selected ] || return 0
  SF_RUN_EXPECTED=$SF_RUN_DOCUMENT python3 - "$1" "$SF_RUN_DATE" <<'PY'
import datetime,json,os,pathlib,re,sys
try:
    p=pathlib.Path(sys.argv[1]);assert p.is_file() and not p.is_symlink() and p.stat().st_size<=16*1024*1024
    def unique(pairs):
        result={}
        for key,value in pairs:
            assert key not in result
            result[key]=value
        return result
    def reject(_): raise ValueError()
    doc=json.loads(p.read_text(),object_pairs_hook=unique,parse_constant=reject)
    run=json.loads(os.environ['SF_RUN_EXPECTED'])
    assert doc['run_selection']==run and doc['audit_date']==sys.argv[2]
    def utc(value):
        assert isinstance(value,str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z',value)
        return datetime.datetime.fromisoformat(value.replace('Z','+00:00'))
    stamp=utc(doc['generated_at'])
    assert utc(run['started_at'])<=stamp<=datetime.datetime.now(datetime.timezone.utc)
except Exception:
    raise SystemExit('RUN-AGGREGATE-FAIL: regenerate the roll-up from the current completed targets')
PY
}
