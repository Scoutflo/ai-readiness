#!/bin/sh
# test-redaction.sh — tests the real redaction library (lib/redaction.sh).
# Fixtures are constructed at runtime so no secret-shaped literal ever sits in
# this file (keeps the leak-scan gate meaningful). Every assertion exits 1 on
# failure; there are no unconditional PASS prints.

set -eu

LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"
. "$LIB_DIR/redaction.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== Redaction Tests (lib-backed) ==="

# Build valid-format dummy secrets at runtime (never stored as literals).
AKIA_KEY="AKIA$(printf 'A%.0s' 1 2 3 4 5 6 7 8)$(printf '1%.0s' 1 2 3 4 5 6 7 8)"   # AKIA + 16 [0-9A-Z]
STRIPE_KEY="sk_test_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)$(printf '9%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"  # 24 chars
BEARER_TOK="Bearer $(printf 'x%.0s' $(seq 1 45))"

echo "Test 1: AWS access key redacted by redact_content"
out=$(printf 'Key: %s end' "$AKIA_KEY" | redact_content)
echo "$out" | grep -q 'AKIA\[REDACTED\]' || fail "AWS key not redacted: $out"
echo "$out" | grep -q "$AKIA_KEY" && fail "raw AWS key survived: $out"
echo "PASS"

echo "Test 2: Stripe test key redacted by redact_content"
out=$(printf 'Token: %s end' "$STRIPE_KEY" | redact_content)
echo "$out" | grep -q 'sk_test_\[REDACTED\]' || fail "Stripe key not redacted: $out"
echo "PASS"

echo "Test 3: Bearer token redacted by redact_content"
out=$(printf 'Auth: %s end' "$BEARER_TOK" | redact_content)
echo "$out" | grep -q 'Bearer \[REDACTED\]' || fail "Bearer token not redacted: $out"
echo "PASS"

echo "Test 4: redact_file redacts in place"
tmp=$(mktemp)
printf 'line1 %s\nline2 %s\n' "$AKIA_KEY" "$STRIPE_KEY" > "$tmp"
redact_file "$tmp"
grep -q "$AKIA_KEY" "$tmp" && fail "redact_file left raw AWS key in place"
grep -q 'AKIA\[REDACTED\]' "$tmp" || fail "redact_file produced no marker"
rm -f "$tmp"
echo "PASS"

echo "Test 5: clean content passes through unchanged (no false positives)"
in="User needs password reset. AKIALOWER not a key."
out=$(printf '%s' "$in" | redact_content)
[ "$in" = "$out" ] || fail "clean content was modified: $out"
echo "PASS"

echo "Test 6: count_redactions counts markers"
n=$(count_redactions "one AKIA[REDACTED] two sk_test_[REDACTED]")
[ "$n" -eq 2 ] || fail "expected 2 markers, got $n"
echo "PASS"

echo "Test 7: NEGATIVE — assertions must be falsifiable"
# Pass the fixture through a no-op instead of the library; the marker check
# must NOT match. If it does, the assertions above are meaningless.
out=$(printf 'Key: %s' "$AKIA_KEY" | sed 's/x/x/')
if echo "$out" | grep -q 'AKIA\[REDACTED\]'; then
  fail "negative control matched — assertions are broken"
fi
echo "PASS (assertions verified falsifiable)"

echo
echo "=== All redaction tests passed ==="
