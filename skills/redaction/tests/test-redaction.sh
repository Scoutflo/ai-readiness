#!/bin/sh
# test-redaction.sh - simple redaction tests

set -eu

echo "=== Redaction Tests ==="

# Test 1: AWS key redacted
echo "Test 1: AWS key redacted"
input="Key: AKIA_TEST_ONLY_XXXX"
output=$(echo "$input" | sed 's/AKIA[0-9A-Z]\{16\}/AKIA[REDACTED]/g')
echo "$output" | grep -q "AKIA\[REDACTED\]" && echo "PASS" || { echo "FAIL: $output"; exit 1; }

# Test 2: Stripe key redacted
echo "Test 2: Stripe key redacted"
input="Token: sk_test_1234567890TESTKEY00000000"
output=$(echo "$input" | sed 's/sk_test_[A-Za-z0-9]\{24,\}/sk_test_[REDACTED]/g')
echo "$output" | grep -q "sk_test_\[REDACTED\]" && echo "PASS" || { echo "FAIL: $output"; exit 1; }

# Test 3: Multiple secrets
echo "Test 3: Multiple secrets redacted"
input="AWS: AKIA_TEST_ONLY_XXXX and Stripe: sk_test_1234567890TESTKEY00000000"
output=$(echo "$input" | sed 's/AKIA[0-9A-Z]\{16\}/AKIA[REDACTED]/g; s/sk_test_[A-Za-z0-9]\{24,\}/sk_test_[REDACTED]/g')
echo "$output" | grep -q "AKIA\[REDACTED\]" && echo "$output" | grep -q "sk_test_\[REDACTED\]" && echo "PASS" || { echo "FAIL: $output"; exit 1; }

# Test 4: No false positives
echo "Test 4: False positives minimized"
input="User needs password reset."
output=$(echo "$input" | sed 's/AKIA[0-9A-Z]\{16\}/AKIA[REDACTED]/g')
[ "$input" = "$output" ] && echo "PASS" || { echo "FAIL: $output"; exit 1; }

echo
echo "=== All redaction tests passed ==="
