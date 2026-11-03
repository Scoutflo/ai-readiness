#!/bin/sh
# Exercise the shipped importer and the actual SKILL.md blocks. All writes go
# to a temporary home in child shells. BC_IMPORT_TEST_LIB permits negative
# controls against a prior or deliberately mutated library, without editing it.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="${BC_IMPORT_TEST_LIB:-$ROOT/skills/business-context/lib/business-context.sh}"
TEST_SHELL="${BC_IMPORT_TEST_SHELL:-/bin/sh}"
TASK_TMP="$(mktemp -d)"
TASK_HOME="$TASK_TMP/home"
mkdir -p "$TASK_HOME"
trap 'rm -rf "$TASK_TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
run() {
  env HOME="$TASK_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" BC_LIB="$LIB" \
    PATH="${BC_TEST_PATH:-$PATH}" BC_REAL_JQ="$(command -v jq)" BC_REAL_MV="$(command -v mv)" \
    "$TEST_SHELL" -c '. "$BC_LIB"; "$@"' sh "$@"
}
keep_pair() {
  cp "$TASK_HOME/.scoutflo/business_context.md" "$TASK_TMP/old.md"
  cp "$TASK_HOME/.scoutflo/business_context.json" "$TASK_TMP/old.json"
}
same_pair() {
  cmp -s "$TASK_TMP/old.md" "$TASK_HOME/.scoutflo/business_context.md" || fail "$1 changed Markdown"
  cmp -s "$TASK_TMP/old.json" "$TASK_HOME/.scoutflo/business_context.json" || fail "$1 changed JSON"
}
cat > "$TASK_TMP/original.md" <<'MD'
# Context
## Environment
- **Stage:** staging
## Cost Sensitivity
- **Primary:** high
## Custom Rules
Keep the original decision.
MD
cat > "$TASK_TMP/replacement.md" <<'MD'
# Replacement context
## Environment
- **Stage:** production
## Cost Sensitivity
- **Primary:** low
MD
printf '%s\n' '# Incomplete context' > "$TASK_TMP/invalid.md"

echo 'Test 1: first import requires no overwrite approval and derives the real projection'
run bc_import_file "$TASK_TMP/original.md" > "$TASK_TMP/out" 2>&1 || fail 'first import failed'
cmp -s "$TASK_TMP/original.md" "$TASK_HOME/.scoutflo/business_context.md" || fail 'first import bytes changed'
jq -e '.environment=="staging" and .cost_sensitivity=="high"' "$TASK_HOME/.scoutflo/business_context.json" >/dev/null || fail 'first projection wrong'
keep_pair

echo 'Test 2: confirmed malformed import fails without replacing either saved file'
if run bc_import_file "$TASK_TMP/invalid.md" --confirm-replace > "$TASK_TMP/out" 2>&1; then
  fail 'malformed import succeeded'
fi
same_pair 'malformed import'

echo 'Test 3: valid replacement without confirmation refuses and preserves the pair'
if run bc_import_file "$TASK_TMP/replacement.md" > "$TASK_TMP/out" 2>&1; then
  fail 'unconfirmed overwrite succeeded'
fi
same_pair 'unconfirmed overwrite'
grep -q -- '--confirm-replace' "$TASK_TMP/out" || fail 'refusal omitted the confirmation hint'

echo 'Test 4: explicit replacement preserves a complete backup and installs matching new files'
run bc_import_file "$TASK_TMP/replacement.md" --confirm-replace > "$TASK_TMP/out" 2>&1 || fail 'confirmed replacement failed'
cmp -s "$TASK_TMP/replacement.md" "$TASK_HOME/.scoutflo/business_context.md" || fail 'replacement bytes changed'
jq -e '.environment=="production" and .cost_sensitivity=="low"' "$TASK_HOME/.scoutflo/business_context.json" >/dev/null || fail 'replacement projection wrong'
backup_found=no
for backup in "$TASK_HOME"/.scoutflo/backups/business-context.*; do
  if [ -f "$backup/business_context.md" ] && cmp -s "$TASK_TMP/old.md" "$backup/business_context.md"; then
    cmp -s "$TASK_TMP/old.json" "$backup/business_context.json" || fail 'backup JSON does not match old Markdown'
    backup_found=yes
  fi
done
[ "$backup_found" = yes ] || fail 'no complete backup of the replaced pair'
keep_pair

echo 'Test 5: derivation failure preserves saved JSON and prevents an import from publishing'
mkdir "$TASK_TMP/fail-jq"
cat > "$TASK_TMP/fail-jq/jq" <<'SH'
#!/bin/sh
[ "${1:-}" != -n ] || exit 73
exec "$BC_REAL_JQ" "$@"
SH
chmod +x "$TASK_TMP/fail-jq/jq"
BC_TEST_PATH="$TASK_TMP/fail-jq:$PATH"
if run bc_derive_json > "$TASK_TMP/out" 2>&1; then fail 'failed projection reported success'; fi
same_pair 'failed standalone derivation'
if run bc_import_file "$TASK_TMP/original.md" --confirm-replace > "$TASK_TMP/out" 2>&1; then fail 'failed staged projection reported success'; fi
same_pair 'failed staged derivation'
unset BC_TEST_PATH

echo 'Test 6: a failure installing the second file restores both old files'
mkdir "$TASK_TMP/fail-mv"
cat > "$TASK_TMP/fail-mv/mv" <<'SH'
#!/bin/sh
[ "${1##*/}" != incoming.md ] || exit 74
exec "$BC_REAL_MV" "$@"
SH
chmod +x "$TASK_TMP/fail-mv/mv"
BC_TEST_PATH="$TASK_TMP/fail-mv:$PATH"
if run bc_import_file "$TASK_TMP/original.md" --confirm-replace > "$TASK_TMP/out" 2>&1; then fail 'failed install reported success'; fi
same_pair 'failed second-file install'
grep -q 'previous context restored' "$TASK_TMP/out" || fail 'failed install did not report its rollback'
unset BC_TEST_PATH
[ ! -d "$TASK_HOME/.scoutflo/.business-context-import.lock" ] || fail 'failed import left its lock'

echo 'Test 7: mistyped declaration keys are counted, warned about and excluded'
cp "$TASK_TMP/replacement.md" "$TASK_TMP/typos.md"
cat >> "$TASK_TMP/typos.md" <<'MD'
## Resource Intent
```yaml
resource_intent:
  - clustr: standby-east
    intent: standby
    why: deliberately held in reserve
```
## Unit of Delivered Value
```yaml
unit_metrics:
  - nmae: sessions
    query: sum(increase(sessions_total[30d]))
    source: prometheus
```
MD
run bc_import_file "$TASK_TMP/typos.md" --confirm-replace > "$TASK_TMP/out" 2> "$TASK_TMP/err" || fail 'typo-bearing valid document could not be imported'
grep -q 'dropped 1 resource_intent and 1 unit_metrics' "$TASK_TMP/err" || fail 'mistyped declarations disappeared without diagnostics'
jq -e '.resource_intent==[] and .unit_metrics==[]' "$TASK_HOME/.scoutflo/business_context.json" >/dev/null || fail 'mistyped declarations took effect'

echo 'Test 8: every published bash block runs in a fresh shell with explicit fixture inputs'
mkdir "$TASK_TMP/blocks"
awk -v out="$TASK_TMP/blocks" '
  /^[[:space:]]*```bash/{inside=1; n++; next}
  inside && /^[[:space:]]*```/{inside=0; close(file); next}
  inside { file=out "/block-" n ".sh"; sub(/^  /, ""); print > file }
' "$ROOT/skills/business-context/SKILL.md"
printf '%s\n\n\n' 'Never rewrite $(this text) or `this text`.' > "$TASK_TMP/pasted.txt"
for block in "$TASK_TMP"/blocks/*.sh; do
  sed -e "s|^CUSTOM_RULES_FILE=.*|CUSTOM_RULES_FILE=\"$TASK_TMP/pasted.txt\"|" \
      -e "s|^CONTEXT_FILE=.*|CONTEXT_FILE=\"$TASK_TMP/replacement.md\"|" \
      -e 's/^CONFIRM_REPLACE=no$/CONFIRM_REPLACE=yes/' "$block" > "$TASK_TMP/execute.sh"
  env HOME="$TASK_HOME" CLAUDE_PLUGIN_ROOT="$ROOT" "$TEST_SHELL" "$TASK_TMP/execute.sh" > "$TASK_TMP/out" 2>&1 \
    || { cat "$TASK_TMP/out" >&2; fail "fresh-shell block failed: $(basename "$block")"; }
  if grep -q 'bc_append_custom' "$block"; then
    tail -c "$(wc -c < "$TASK_TMP/pasted.txt" | tr -d ' ')" "$TASK_HOME/.scoutflo/business_context.md" > "$TASK_TMP/paste-tail.txt"
    cmp -s "$TASK_TMP/pasted.txt" "$TASK_TMP/paste-tail.txt" || fail 'paste block changed text or trailing newlines'
  fi
done

echo 'Test 9: quoted and backslash table values survive import and JSON encoding'
cp "$TASK_TMP/replacement.md" "$TASK_TMP/quoted.md"
cat >> "$TASK_TMP/quoted.md" <<'MD'
## Environment Map
| Environment | AWS profile | GCP project | Kube context | Region | Uptime SLA |
| --- | --- | --- | --- | --- | --- |
| staging "blue" | example\reader | example-project | example-context | region-a | 99.9% |
## SLAs / SLOs
| Service | SLA |
| --- | --- |
| payments "api" | 99.9% |
| worker\batch | 99% |
MD
run bc_import_file "$TASK_TMP/quoted.md" --confirm-replace > "$TASK_TMP/out" 2> "$TASK_TMP/err" || fail 'quoted table import failed'
jq -e '.environment_map==[{environment:"staging \"blue\"",aws_profile:"example\\reader",gcp_project:"example-project",kube_context:"example-context",region:"region-a",uptime_sla:"99.9%"}]
  and .service_slas==[{service:"payments \"api\"",sla:"99.9%"},{service:"worker\\batch",sla:"99%"}]' \
  "$TASK_HOME/.scoutflo/business_context.json" >/dev/null || fail 'quoted/backslash fields disappeared or changed'
keep_pair

echo 'Test 10: table projection errors are visible and preserve both saved files'
mkdir "$TASK_TMP/fail-table-jq"
cat > "$TASK_TMP/fail-table-jq/jq" <<'SH'
#!/bin/sh
[ "${1:-}" != -Rs ] || { echo 'fixture table parser failure' >&2; exit 75; }
exec "$BC_REAL_JQ" "$@"
SH
chmod +x "$TASK_TMP/fail-table-jq/jq"
BC_TEST_PATH="$TASK_TMP/fail-table-jq:$PATH"
if run bc_derive_json > "$TASK_TMP/out" 2> "$TASK_TMP/err"; then fail 'table projection error reported success'; fi
same_pair 'table projection failure'
grep -q 'failed to derive Environment Map' "$TASK_TMP/err" || fail 'table projection failure was silent'
if run bc_import_file "$TASK_TMP/quoted.md" --confirm-replace > "$TASK_TMP/out" 2> "$TASK_TMP/err"; then fail 'failed table import published'; fi
same_pair 'table import projection failure'
unset BC_TEST_PATH

echo 'Test 11: direct paste preserves both missing final newline and multiple trailing newlines'
for newline_count in 0 3; do
  printf '%s' 'Keep $(this) and `this` literally.' > "$TASK_TMP/bytes.txt"
  i=0; while [ "$i" -lt "$newline_count" ]; do printf '\n' >> "$TASK_TMP/bytes.txt"; i=$((i+1)); done
  run bc_append_custom < "$TASK_TMP/bytes.txt" > "$TASK_TMP/out" 2>&1 || fail 'byte-preserving paste failed'
  tail -c "$(wc -c < "$TASK_TMP/bytes.txt" | tr -d ' ')" "$TASK_HOME/.scoutflo/business_context.md" > "$TASK_TMP/paste-tail.txt"
  cmp -s "$TASK_TMP/bytes.txt" "$TASK_TMP/paste-tail.txt" || fail 'direct paste changed final newlines'
done

echo 'BUSINESS-CONTEXT-IMPORT-OK (11 cases; real library and fresh-shell skill blocks)'
