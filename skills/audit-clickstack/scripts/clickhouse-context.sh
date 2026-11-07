#!/bin/sh
# Stateless selected-target context; credentials never enter command arguments.
set -eu
set +x
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
CH_KEY_VAR=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_password_env)
[ -n "$CH_KEY_VAR" ] || CH_KEY_VAR=CH_KEY
CH_KEY=$(cs_secret clickhouse_password_env CH_KEY)
[ -n "$CH_URL" ] && [ -n "$CH_KEY" ] || { echo 'Selected ClickHouse URL/credential missing; no fallback.' >&2; return 2; }
chq() {
  [ "$#" -eq 1 ] || { echo 'Pass one fixed read-only SQL statement.' >&2; return 2; }
  { printf '%s\n' "$CH_KEY"; printf '%s' "$1"; } | python3 "${CS_ROOT}/skills/audit-clickstack/scripts/clickhouse-read.py" query "$CH_URL" "$CH_USER" "$CS_SEG" "$CH_KEY_VAR" "$CS_OUT/raw/clickhouse-probe.json"
}
chq_default_probe() {
  printf '%s\n' "$CH_KEY" | python3 "${CS_ROOT}/skills/audit-clickstack/scripts/clickhouse-read.py" default-probe "$CH_URL" "$CH_USER" "$CS_SEG" "$CH_KEY_VAR" "$CS_OUT/raw/clickhouse-probe.json"
}
