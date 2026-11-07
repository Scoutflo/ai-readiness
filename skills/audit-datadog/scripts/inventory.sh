#!/bin/sh
# Fixed read-only inventory recipe; every page is projected before it can be saved.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
umask 077
dd_credentials
mkdir -p "$RAW_DIR"
# A failed rerun cannot leave yesterday's successful input under today's name.
for _dd_name in monitors monitor-quality downtimes slos alert-events alert-events-v2-count synthetics source-routing-evidence; do rm -f "$RAW_DIR/$_dd_name.json"; done

dd_pages() {
  _dd_surface=$1; _dd_base=$2; _dd_limit=$3; _dd_style=$4; _dd_output=$5
  _dd_all='[]'; _dd_page=0
  while [ "$_dd_page" -lt 20 ]; do
    case "$_dd_style" in
      monitors) _dd_query="page_size=$_dd_limit&page=$_dd_page";;
      quality) _dd_query="per_page=$_dd_limit&page=$_dd_page";;
      downtime) _dd_query="page[limit]=$_dd_limit&page[offset]=$((_dd_page*_dd_limit))";;
      slo) _dd_query="limit=$_dd_limit&offset=$((_dd_page*_dd_limit))";;
    esac
    _dd_page_data=$(dd_read "$_dd_surface" "$_dd_base?$_dd_query") || return 2
    _dd_len=$(printf '%s' "$_dd_page_data" | jq length)
    _dd_all=$(printf '%s\n%s' "$_dd_all" "$_dd_page_data" | jq -s 'add')
    printf '%s' "$_dd_all" | jq -e '([.[].id]|length)==([.[].id]|unique|length)' >/dev/null || { echo 'Datadog pagination repeated an ID; inventory remains blocked.' >&2; return 2; }
    if [ "$_dd_len" -lt "$_dd_limit" ]; then
      printf '%s\n' "$_dd_all" > "$RAW_DIR/$_dd_output"
      dd_stamp "$_dd_output"; return 0
    fi
    _dd_page=$((_dd_page+1))
  done
  echo 'Datadog inventory exceeded 20 pages; narrow the declared scope and repeat; no complete inventory published.' >&2
  return 2
}

dd_pages monitors /api/v1/monitor 1000 monitors monitors.json
dd_pages quality /api/v1/monitor/search 1000 quality monitor-quality.json
dd_pages downtimes /api/v2/downtime 100 downtime downtimes.json
# Re-read the authoritative count: movement/partial pages cannot become missing-monitor claims.
_dd_count=$(dd_read counts '/api/v1/monitor/search?per_page=1' | jq -r .count)
[ "$(jq length "$RAW_DIR/monitors.json")" = "$_dd_count" ] && [ "$(jq length "$RAW_DIR/monitor-quality.json")" = "$_dd_count" ] || {
  rm -f "$RAW_DIR/monitors.json" "$RAW_DIR/monitor-quality.json"
  echo 'Datadog monitor inventory changed or is incomplete; repeat the snapshot.' >&2; exit 2;
}
dd_pages slos /api/v1/slo 1000 slo slos.json || echo 'SLO-dependent checks blocked.' >&2
_dd_to=$(date -u +%s); _dd_from=$((_dd_to-30*86400))
dd_capture events "/api/v1/events?start=$_dd_from&end=$_dd_to&sources=alert" alert-events.json || echo 'Event-history checks blocked.' >&2
dd_capture events-v2 /api/v2/events/search alert-events-v2-count.json || echo 'v2 event corroboration blocked.' >&2
dd_capture synthetics /api/v1/synthetics/tests synthetics.json || echo 'Synthetic-dependent checks blocked.' >&2
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/source-evidence.sh"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/export-inventory.sh"
printf 'Datadog safe inventory captured for %s on %s.\n' "$DD_SEG" "$DD_SITE"
