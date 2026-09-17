#!/bin/sh
# test-migration-plan.sh — hermetic tests for the migration-plan disposition lib
# + the check-migration-plan.sh validator. Run by ci/run-tests.sh under /bin/sh.
# No network, no creds, synthetic fixtures only.
set -u

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
LIB="$DIR/lib/migration-plan.sh"
CHECK="$ROOT/report-standard/check-migration-plan.sh"
[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB"; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: validator not found at $CHECK"; exit 1; }

WORK="${TMPDIR:-/tmp}/mig-test.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=$3 got=$2)"; fi; }

DATE="2026-09-17"
export SCOUTFLO_AUDIT_DIR="$WORK/audits"

# --- fixtures: a datadog run (inventory + findings), a two-level signoz target,
# --- and measured fatigue signals -------------------------------------------
mkdir -p "$SCOUTFLO_AUDIT_DIR/datadog/$DATE" "$SCOUTFLO_AUDIT_DIR/signoz/my-host/$DATE"
cat > "$SCOUTFLO_AUDIT_DIR/datadog/$DATE/inventory.json" <<'EOF'
{"schema":"scoutflo-inventory/v1","target":"datadog","counts":{"total":10},"items":[
 {"name":"mon-healthy","kind":"monitor","covers":"checkout","enabled":true,"routes_to":"slack-payments"},
 {"name":"mon-never-fired","kind":"monitor","enabled":true,"routes_to":"slack-payments"},
 {"name":"mon-placeholder","kind":"monitor","enabled":true,"routes_to":"none"},
 {"name":"mon-dup-on-target","kind":"monitor","enabled":true,"routes_to":"slack-payments"},
 {"name":"api-uptime-check","kind":"synthetic_test","enabled":true},
 {"name":"slo-checkout","kind":"slo","enabled":true},
 {"name":"dt-weekly","kind":"downtime","enabled":false},
 {"name":"mon-dead-end","kind":"monitor","enabled":true,"routes_to":"sns-empty"},
 {"name":"mon-dead-dup","kind":"monitor","enabled":true},
 {"name":"mon-zero-fires","kind":"monitor","enabled":true}
]}
EOF
cat > "$SCOUTFLO_AUDIT_DIR/datadog/$DATE/findings.json" <<'EOF'
{"schema":"scoutflo-findings/v2","target":"datadog","findings":[
 {"id":"DD-037","title":"Monitor never evaluated once since creation","severity":"medium","affected":["mon-never-fired","mon-dead-dup"]},
 {"id":"DD-007","title":"Only notification target is a placeholder handle","severity":"high","affected":["mon-placeholder"]}
]}
EOF
cat > "$SCOUTFLO_AUDIT_DIR/signoz/my-host/$DATE/inventory.json" <<'EOF'
{"schema":"scoutflo-inventory/v1","target":"signoz/my-host","counts":{"total":2},"items":[
 {"name":"mon-dup-on-target","kind":"alert_rule","enabled":true},
 {"name":"mon-dead-dup","kind":"alert_rule","enabled":true}
]}
EOF
cat > "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json" <<'EOF'
{"schema":"scoutflo-fatigue-signals/v1","signals":[
 {"provider":"datadog","target":"datadog","object_id":"mon-dead-end","object_kind":"monitor","fires":12,"reaches_human":false,"reach_reason":"routes to an empty target","source_finding_ids":[]},
 {"provider":"datadog","target":"datadog","object_id":"mon-zero-fires","object_kind":"monitor","fires":0,"reaches_human":true,"source_finding_ids":[]}
]}
EOF

. "$LIB"

echo "== full-mode run =="
migration_plan_run datadog signoz "$DATE" >/dev/null 2>&1
OUT="$SCOUTFLO_AUDIT_DIR/migration-plans/datadog-to-signoz/$DATE/migration-plan.json"
[ -f "$OUT" ] || { echo "FAIL: migration-plan.json not written"; exit 1; }

disp() { jq -r --arg n "$1" '.inventory[] | select(.name == $n) | .disposition' "$OUT"; }
check "schema"                          "$(jq -r '.schema' "$OUT")" "scoutflo-migration-plan/v1"
check "mode is full (target found)"     "$(jq -r '.mode' "$OUT")" "full"
check "healthy monitor -> migrate"      "$(disp mon-healthy)" "migrate"
check "never-evaluated -> drop-candidate" "$(disp mon-never-fired)" "drop-candidate"
check "drop cites DD-037"               "$(jq -r '.inventory[] | select(.name == "mon-never-fired") | .evidence[0].finding_id' "$OUT")" "DD-037"
check "placeholder handle -> fix-then-migrate" "$(disp mon-placeholder)" "fix-then-migrate"
check "target match -> already-covered" "$(disp mon-dup-on-target)" "already-covered"
check "already-covered names the match" "$(jq -r '.inventory[] | select(.name == "mon-dup-on-target") | .matched_target' "$OUT")" "mon-dup-on-target"
check "synthetics -> no-equivalent"     "$(disp api-uptime-check)" "no-equivalent"
check "slo -> migrate (manual default)" "$(disp slo-checkout)" "migrate"
check "slo default equivalence manual"  "$(jq -r '.inventory[] | select(.name == "slo-checkout") | .equivalence_default' "$OUT")" "manual"
check "disabled downtime flagged"       "$(jq -r '.inventory[] | select(.name == "dt-weekly") | .flags[0]' "$OUT")" "disabled-at-source"
check "dead-end signal -> fix-then-migrate" "$(disp mon-dead-end)" "fix-then-migrate"
check "zero-fires signal -> drop-candidate" "$(disp mon-zero-fires)" "drop-candidate"
check "precedence: covered beats drop"  "$(disp mon-dead-dup)" "already-covered"
check "totals reconcile (objects)"      "$(jq -r '.totals.objects' "$OUT")" "10"
check "gaps carry the synthetics kind"  "$(jq -r '.gaps[0].kind' "$OUT")" "synthetic_test"
check "history honesty locked"          "$(jq -r '.cutover.historical_telemetry' "$OUT")" "does-not-transfer"

echo "== validator: raw skeleton must FAIL (pending-catalog gap alternative) =="
if sh "$CHECK" "$OUT" >/dev/null 2>&1; then bad "validator passed a skeleton with a pending-catalog gap"; else ok "validator rejects unfilled gap alternative"; fi

echo "== validator: enriched plan PASSES =="
jq '.gaps[0].alternative = "no native synthetics on the target; keep the existing external uptime checks (see pair catalog)"' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
if sh "$CHECK" "$OUT" "$SCOUTFLO_AUDIT_DIR" "$DATE" >/dev/null 2>&1; then ok "validator passes the enriched plan (with evidence cross-check)"; else bad "validator rejected a valid enriched plan"; fi

echo "== validator red paths =="
jq '(.inventory[] | select(.name == "mon-never-fired") | .evidence) = []' "$OUT" > "$WORK/red1.json"
if sh "$CHECK" "$WORK/red1.json" >/dev/null 2>&1; then bad "validator passed an evidence-free drop-candidate"; else ok "evidence-free drop-candidate fails closed"; fi

jq '.mode = "source-only"' "$OUT" > "$WORK/red2.json"
if sh "$CHECK" "$WORK/red2.json" >/dev/null 2>&1; then bad "validator passed already-covered in source-only mode"; else ok "already-covered in source-only mode fails closed"; fi

jq '.cutover.historical_telemetry = "transfers"' "$OUT" > "$WORK/red3.json"
if sh "$CHECK" "$WORK/red3.json" >/dev/null 2>&1; then bad "validator passed a history-transfers claim"; else ok "history-transfers claim fails closed"; fi

jq '(.inventory[] | select(.name == "mon-never-fired") | .evidence[0].finding_id) = "DD-999"' "$OUT" > "$WORK/red4.json"
if sh "$CHECK" "$WORK/red4.json" "$SCOUTFLO_AUDIT_DIR" "$DATE" >/dev/null 2>&1; then bad "validator passed a ghost finding-id"; else ok "ghost evidence finding-id fails closed (never-fabricate cross-check)"; fi

jq '(.inventory[] | select(.name == "mon-healthy") | .equivalence) = "automatic"' "$OUT" > "$WORK/red5.json"
if sh "$CHECK" "$WORK/red5.json" >/dev/null 2>&1; then bad "validator passed an out-of-enum equivalence"; else ok "out-of-enum equivalence fails closed"; fi

jq '.totals.migrate = 99' "$OUT" > "$WORK/red6.json"
if sh "$CHECK" "$WORK/red6.json" >/dev/null 2>&1; then bad "validator passed non-reconciling totals"; else ok "non-reconciling totals fail closed"; fi

echo "== source-only mode (no target artifacts) =="
rm -rf "$SCOUTFLO_AUDIT_DIR/signoz" "$SCOUTFLO_AUDIT_DIR/migration-plans"
migration_plan_run datadog signoz "$DATE" >/dev/null 2>&1
check "mode is source-only"             "$(jq -r '.mode' "$OUT")" "source-only"
check "no already-covered in source-only" "$(jq -r '[ .inventory[] | select(.disposition == "already-covered") ] | length' "$OUT")" "0"
check "dup becomes migrate in source-only" "$(disp mon-dup-on-target)" "migrate"

echo "== honest failures =="
if migration_plan_run datadog grafana "$DATE" >/dev/null 2>&1; then bad "unsupported pair did not fail"; else ok "unsupported pair fails honestly (no improvised mapping)"; fi
if migration_plan_run datadog signoz "1999-01-01" >/dev/null 2>&1; then bad "missing source inventory did not fail"; else ok "missing source inventory fails with guidance"; fi

echo "== SKILL block execution (hermetic regression locks for the v0.1.194 flow bugs) =="
# Extract every fenced bash block from SKILL.md and locate the doctor + sizing
# blocks by content signature (numbering-independent). No network: only the
# fail-closed paths that exit BEFORE any curl are executed.
BLKDIR="$WORK/blocks"; mkdir -p "$BLKDIR"
awk '/^```bash$/{f=1; n++; next} /^```$/{f=0} f{print > ("'"$BLKDIR"'/blk" n ".sh")}' "$DIR/SKILL.md"
DOCTOR=""; SIZING=""
for b in "$BLKDIR"/blk*.sh; do
  grep -q 'identity gate' "$b" && DOCTOR="$b"
  grep -q 'cli_pause_before_audit' "$b" && SIZING="$b"
done
[ -n "$DOCTOR" ] && [ -n "$SIZING" ] || { echo "FAIL: could not locate doctor/sizing blocks in SKILL.md"; exit 1; }

# doctor block, fresh shell, no config anywhere -> fail-closed with guidance
mkdir -p "$WORK/nohome"
OUT1="$(cd "$WORK/nohome" && env -i HOME="$WORK/nohome" PATH="$PATH" sh "$DOCTOR" 2>&1 || true)"
printf '%s' "$OUT1" | grep -q 'no toolkit.yaml' \
  && ok "doctor block fails closed with no config (fresh shell)" \
  || bad "doctor block no-config path wrong: $OUT1"

# doctor block, config present but keys UNSET -> must stop at the :? guard BEFORE any network call
mkdir -p "$WORK/home/.scoutflo"
printf 'datadog:\n  api_key_env: DATADOG_API_KEY\n' > "$WORK/home/.scoutflo/toolkit.yaml"
if OUT2="$(cd "$WORK/home" && env -i HOME="$WORK/home" PATH="$PATH" sh "$DOCTOR" 2>&1)"; then
  bad "doctor block passed with unset keys (empty-header risk)"
else
  printf '%s' "$OUT2" | grep -q 'source key missing' \
    && ok "doctor block fails closed on unset keys (E5 lock, pre-network)" \
    || bad "doctor block unset-key message wrong: $OUT2"
fi

# sizing block, fresh shell, MULTI-LABEL layout -> must count across both layouts (v0.1.194 dual-glob lock)
SZDIR="$WORK/sizing"; mkdir -p "$SZDIR/datadog/orgA/$DATE" "$SZDIR/datadog/orgB/$DATE"
printf '{"items":[{"n":1},{"n":2},{"n":3}]}' | jq '{items: [.items[]]}' > "$SZDIR/datadog/orgA/$DATE/inventory.json"
printf '{"items":[{"n":4}]}' > "$SZDIR/datadog/orgB/$DATE/inventory.json"
OUT3="$(env -i HOME="$WORK" PATH="$PATH" SCOUTFLO_AUDIT_DIR="$SZDIR" RUN_DATE="$DATE" CLAUDE_PLUGIN_ROOT="$ROOT" sh "$SIZING" 2>&1 || true)"
printf '%s' "$OUT3" | grep -q 'estate: 4 source objects' \
  && ok "sizing block dual-globs a labeled source (counts 4)" \
  || bad "sizing block multi-label count wrong: $OUT3"
# one-level layout still counted
SZ2="$WORK/sizing2"; mkdir -p "$SZ2/datadog/$DATE"
printf '{"items":[{"n":1}]}' > "$SZ2/datadog/$DATE/inventory.json"
OUT4="$(env -i HOME="$WORK" PATH="$PATH" SCOUTFLO_AUDIT_DIR="$SZ2" RUN_DATE="$DATE" CLAUDE_PLUGIN_ROOT="$ROOT" sh "$SIZING" 2>&1 || true)"
printf '%s' "$OUT4" | grep -q 'estate: 1 source objects' \
  && ok "sizing block still counts the one-level layout (counts 1)" \
  || bad "sizing block one-level count wrong: $OUT4"

echo "migration-plan: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
