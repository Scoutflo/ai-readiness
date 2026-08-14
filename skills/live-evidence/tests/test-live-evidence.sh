#!/bin/sh
# test-live-evidence.sh — behavior tests for the read-only live-evidence lib.
# No live cluster is touched: we test the guard logic and redaction, which are
# the safety-critical parts, without invoking kubectl against anything real.
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/skills/live-evidence/lib/live-evidence.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== live-evidence lib self-test ==="

[ -f "$LIB" ] || fail "lib not found: $LIB"
# shellcheck disable=SC1090
. "$LIB"

echo "Test 1: the probe + guard functions are defined"
for fn in le_verb_ok le_kubectl le_redact probe_pod_status probe_events probe_rollout probe_owner probe_logs_previous le_can_probe; do
  command -v "$fn" >/dev/null 2>&1 || fail "function not defined: $fn"
done
echo "PASS"

echo "Test 2: le_verb_ok accepts read verbs, rejects mutating ones"
for v in get describe list logs top events version api-resources auth config; do
  le_verb_ok "$v" || fail "le_verb_ok rejected an allowed read verb: $v"
done
for v in delete apply patch scale exec rollout create edit annotate; do
  le_verb_ok "$v" && fail "le_verb_ok accepted a mutating verb: $v"
done
echo "PASS"

echo "Test 3: le_kubectl refuses a non-read verb WITHOUT invoking kubectl"
# Shadow kubectl so any accidental invocation is loudly wrong.
kubectl() { echo "KUBECTL-WAS-CALLED $*"; }
out="$(le_kubectl some-ctx delete pod x 2>&1 || true)"
printf '%s' "$out" | grep -q "KUBECTL-WAS-CALLED" && fail "le_kubectl invoked kubectl for a forbidden verb"
printf '%s' "$out" | grep -qi "refusing non-read" || fail "le_kubectl did not refuse the forbidden verb with a reason"
echo "PASS"

echo "Test 4: le_kubectl refuses an empty context (never trusts ambient)"
out="$(le_kubectl "" get pods 2>&1 || true)"
printf '%s' "$out" | grep -q "KUBECTL-WAS-CALLED" && fail "le_kubectl ran with no explicit context"
printf '%s' "$out" | grep -qi "no explicit --context" || fail "le_kubectl did not refuse an empty context"
echo "PASS"

echo "Test 5: le_kubectl passes an allowed verb through to kubectl with --context pinned"
out="$(le_kubectl my-ctx get pods 2>&1 || true)"
printf '%s' "$out" | grep -q "KUBECTL-WAS-CALLED" || fail "le_kubectl did not invoke kubectl for an allowed verb"
printf '%s' "$out" | grep -q -- "--context my-ctx" || fail "le_kubectl did not pin --context"
printf '%s' "$out" | grep -q -- "--request-timeout" || fail "le_kubectl did not bound the call with --request-timeout"
unset -f kubectl
echo "PASS"

echo "Test 6: le_redact strips known secret shapes from a log slice"
red="$(printf 'user token AKIAIOSFODNN7EXAMPLE and Bearer %s\n' "$(printf 'a%.0s' $(seq 1 45))" | le_redact)"
printf '%s' "$red" | grep -q "AKIAIOSFODNN7EXAMPLE" && fail "le_redact left an AWS access key id in the output"
printf '%s' "$red" | grep -q "REDACTED" || fail "le_redact did not redact anything"
echo "PASS"

echo
echo "=== live-evidence lib self-test passed ==="
