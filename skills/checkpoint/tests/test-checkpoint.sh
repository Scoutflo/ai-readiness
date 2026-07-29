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
echo "=== All checkpoint tests passed ==="
