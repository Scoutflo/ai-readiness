#!/bin/sh
set -eu
echo "=== Cross-References Tests ==="
echo "Test 1: Library loads without error"
. skills/cross-references/lib/cross-references.sh
echo "PASS"
echo "Test 2: Functions exist"
type xref_find_related > /dev/null && echo "PASS" || { echo "FAIL"; exit 1; }
type xref_add_to_report > /dev/null && echo "PASS" || { echo "FAIL"; exit 1; }
echo "=== All cross-reference tests passed ==="
