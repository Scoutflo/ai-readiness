#!/bin/sh
set -eu
TEST_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT
echo "=== Checkpoint Tests ==="
echo "Test 1: Batch size calculation"
. skills/checkpoint/lib/checkpoint.sh
size=$(checkpoint_get_batch_size 50)
[ "$size" = "1" ] && echo "PASS" || { echo "FAIL: $size"; exit 1; }
size=$(checkpoint_get_batch_size 250)
[ "$size" = "100" ] && echo "PASS" || { echo "FAIL: $size"; exit 1; }
size=$(checkpoint_get_batch_size 1500)
[ "$size" = "200" ] && echo "PASS" || { echo "FAIL: $size"; exit 1; }
echo "Test 2: Batch count"
batches=$(checkpoint_batch_resources 1000 200)
[ "$batches" = "5" ] && echo "PASS" || { echo "FAIL: $batches"; exit 1; }
echo "Test 3: Scope save/load/reset"
TOPOLOGY_FILE="$TEST_DIR/topology.json"   # never touch the real ~/.scoutflo
printf '%s\n' '{"business_context":{"environment":"dr"}}' > "$TOPOLOGY_FILE"
checkpoint_save_scope " api , worker,, "
scope=$(checkpoint_load_scope)
[ "$scope" = "api,worker" ] && echo "PASS" || { echo "FAIL: names not trimmed: $scope"; exit 1; }
jq -e '.business_context.environment == "dr"' "$TOPOLOGY_FILE" >/dev/null && echo "PASS" || { echo "FAIL: save dropped business_context"; exit 1; }
odd='we"ird\svc'
checkpoint_save_scope "$odd"
scope=$(checkpoint_load_scope)
[ "$scope" = "$odd" ] && echo "PASS" || { echo "FAIL: quote/backslash name not round-tripped: $scope"; exit 1; }
checkpoint_save_scope "all"
scope=$(checkpoint_load_scope)
[ "$scope" = "all" ] && ! jq -e 'has("audit_scope")' "$TOPOLOGY_FILE" >/dev/null && echo "PASS" || { echo "FAIL: 'all' did not clear the scope: $scope"; exit 1; }
checkpoint_save_scope "api"
checkpoint_reset_scope
scope=$(checkpoint_load_scope)
[ "$scope" = "all" ] && echo "PASS" || { echo "FAIL: reset kept $scope"; exit 1; }
echo "=== All checkpoint tests passed ==="
