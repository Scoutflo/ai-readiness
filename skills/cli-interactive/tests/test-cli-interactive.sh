#!/bin/sh
set -eu
echo "=== CLI Interactive Tests ==="
. skills/cli-interactive/lib/cli-interactive.sh
echo "Test 1: Build exclusion filter"
filter=$(cli_build_exclusion_filter "lambda,s3" "us-east-1" "stopped")
echo "$filter" | grep -q "exclude-services=lambda,s3" && echo "PASS" || { echo "FAIL"; exit 1; }
echo "Test 2: Empty exclusions"
filter=$(cli_build_exclusion_filter "" "" "")
[ -z "$filter" ] && echo "PASS" || { echo "FAIL"; exit 1; }
echo "=== All CLI tests passed ==="
