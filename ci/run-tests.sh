#!/bin/sh
# run-tests.sh — discover and run every plugin test suite under /bin/sh.
#
# Why this exists: for eight releases CI ran only leak-scan/structure-check/
# plugin-validate and never executed a single test or shell library, so broken
# code shipped green (the v0.1.69 finding-dropping pipeline, the doctor crash,
# the echo|jq portability break). This runner closes that gap: it is the CI step
# that actually exercises the code.
#
# Discovers: tests/*.sh and skills/*/tests/*.sh whose names start with test- or
# measure-. Runs each under /bin/sh; any non-zero exit fails the whole run.
#
# Also GUARDS against the dead-test class: a file written in bats syntax
# (@test / BATS_TEST_DIRNAME) silently no-ops or crashes on load under /bin/sh,
# which is how five never-running "tests" hid in the repo until v0.1.74. Such a
# file is a HARD FAILURE here — tests must run under the same POSIX sh the
# skills use, not an unavailable bats harness.
set -eu
DIR="${1:-.}"
cd "$DIR"

pass=0; fail=0; failed_list=""

# collect into a portable list (no process-substitution / arrays for dash)
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
find tests skills -type f \( -name 'test-*.sh' -o -name 'measure-*.sh' \) 2>/dev/null | sort > "$TMP"

while IFS= read -r t; do
  [ -n "$t" ] || continue
  # Guard: reject bats-only files that cannot run under /bin/sh. Match only
  # EXECUTABLE bats syntax, not prose in comments — a comment mentioning the
  # word BATS_TEST_DIRNAME (e.g. "replaces a bats stub") is fine; a real
  # `@test "..." {` block or a bare `$BATS_TEST_DIRNAME` expansion is not.
  # Strip comment lines before scanning so documentation never trips the guard.
  code_only="$(sed 's/#.*//' "$t")"
  if printf '%s\n' "$code_only" | grep -qE '^[[:space:]]*@test[[:space:]]|\$\{?BATS_TEST_DIRNAME'; then
    echo "DEAD-TEST: $t uses executable bats syntax (@test block or \$BATS_TEST_DIRNAME) — cannot run under /bin/sh; rewrite as a plain sh suite or delete it"
    fail=$((fail + 1)); failed_list="$failed_list $t"
    continue
  fi
  printf '── %s\n' "$t"
  if sh "$t" > "/tmp/rt.$$.log" 2>&1; then
    pass=$((pass + 1)); echo "   PASS"
  else
    fail=$((fail + 1)); failed_list="$failed_list $t"
    echo "   FAIL (exit $?):"; sed 's/^/     /' "/tmp/rt.$$.log" | tail -15
  fi
done < "$TMP"
rm -f "/tmp/rt.$$.log"

echo "───────────────────────────────"
echo "TEST SUITES: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo "FAILED:$failed_list"
  echo "TESTS-FAILED"
  exit 1
fi
echo "TESTS-OK ($pass suites)"
