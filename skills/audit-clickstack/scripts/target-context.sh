#!/bin/sh
# Sourced selected-target context. No network calls and no secret output.
set +x
set -eu
CS_ROOT="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must name the plugin root}"
CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$CFG" ]; then
  for cs_file in ./.scoutflo/toolkit.yaml "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    if [ -f "$cs_file" ]; then CFG=$cs_file; break; fi
  done
fi
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'ClickStack blocked: select an existing config' >&2; return 1; }
TT="$CS_ROOT/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind)
CS_N=$(sh "$TT" "$CFG" clickstack count)
[ "$CS_N" -gt 0 ] || { echo 'ClickStack blocked: no configured target' >&2; return 1; }
[ "$CS_N" -le 1 ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'ClickStack blocked: select SCOUTFLO_TARGET for the labeled list' >&2; return 1; }
CS_IDX=0; cs_matches=0; cs_i=0
while [ "$cs_i" -lt "$CS_N" ]; do
  cs_label=$(sh "$TT" "$CFG" clickstack label "$cs_i")
  case "$cs_label" in ''|*[!A-Za-z0-9_-]*) echo 'ClickStack blocked: invalid target label' >&2; return 1 ;; esac
  if [ "$CS_KIND" = map ] || [ -z "${SCOUTFLO_TARGET:-}" ] || [ "$cs_label" = "$SCOUTFLO_TARGET" ]; then CS_IDX=$cs_i; cs_matches=$((cs_matches+1)); fi
  cs_i=$((cs_i+1))
done
[ "$cs_matches" -eq 1 ] || { echo 'ClickStack blocked: target must match exactly one configured label' >&2; return 1; }
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
CS_SEG=clickstack
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/$CS_LABEL"; fi
CH_URL=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_url)
HDX_URL=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_url)
CH_USER=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_user)
[ -n "$CH_USER" ] || CH_USER=scoutflo_ro
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f ./.scoutflo/env ]; then SCOUTFLO_ENV=./.scoutflo/env; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
cs_secret() {
  cs_var=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" "$1")
  [ -n "$cs_var" ] || cs_var=$2
  case "$cs_var" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
  sh -c 'set +x; set -a; [ ! -f "$1" ] || . "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$cs_var" 2>/dev/null || true
}
CS_RUN_DATE="${SCOUTFLO_CLICKSTACK_RUN_DATE:-$(date -u +%F)}"
python3 -c 'import datetime,re,sys; assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}",sys.argv[1]); d=datetime.date.fromisoformat(sys.argv[1]); assert d<=datetime.datetime.now(datetime.timezone.utc).date()' "$CS_RUN_DATE" >/dev/null 2>&1 || { echo 'ClickStack blocked: invalid run date' >&2; return 1; }
CS_OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/$CS_SEG/$CS_RUN_DATE"
