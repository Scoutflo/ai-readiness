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
# A read-looking top-level verb can still mutate local access configuration.
for args in 'config use-context other' 'config set-context other' 'auth reconcile -f roles.yaml'   'get pods --context other' 'get pods --context=other' 'get pods --kubeconfig=other'   'get pods --server=https://other.example.com' 'get pods -s https://other.example.com'   'get pods --as other' 'get pods --token=fixture' 'get pods --request-timeout=0' 'config view --raw'   'config --kubeconfig=other view'; do
  set -- $args
  if out="$(le_kubectl my-ctx "$@" 2>&1)"; then fail "le_kubectl accepted forbidden subcommand or identity override: $args"; fi
  printf '%s' "$out" | grep -q 'KUBECTL-WAS-CALLED' && fail "forbidden subcommand or override reached kubectl: $args"
done
for args in 'config view --minify' 'auth can-i get pods'; do
  set -- $args
  out="$(le_kubectl my-ctx "$@" 2>&1)" || fail "required readonly subcommand rejected: $args"
  printf '%s' "$out" | grep -q 'KUBECTL-WAS-CALLED' || fail "required readonly subcommand did not reach stub: $args"
done
echo "PASS (read-only subcommands and pinned identity)"
unset -f kubectl
echo "PASS"

echo "Test 6a: the actual readiness path still resolves a context and authorizes a read"
kubectl() {
  case " $* " in
    *' config get-contexts '*) printf '%s\n' my-ctx ;;
    *' auth can-i '*) printf '%s\n' yes ;;
    *) return 97 ;;
  esac
}
le_can_probe my-ctx || fail "actual le_can_probe healthy path regressed"
if le_can_probe other-ctx; then fail "le_can_probe accepted absent context"; fi

echo "Test 6aa: successful probe fields and two-read ownership remain intact"
kubectl() {
  case " $* " in
    *' get pod '*) printf '%s\n' '{"metadata":{"ownerReferences":[{"kind":"ReplicaSet","name":"fixture-rs"}]},"status":{"phase":"Running","containerStatuses":[{"name":"app","restartCount":2,"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}' ;;
    *' get rs '*) printf '%s\n' '{"metadata":{"ownerReferences":[{"kind":"Deployment","name":"fixture-deploy"}]}}' ;;
    *' get events '*) printf '%s\n' '{"items":[{"reason":"BackOff","count":2}]}' ;;
    *' get deploy '*) printf '%s\n' '{"status":{"replicas":2,"readyReplicas":1,"unavailableReplicas":1}}' ;;
    *' logs '*) printf '%s\n' 'fixture log line' ;;
    *) return 97 ;;
  esac
}
probe_pod_status my-ctx fixture pod | jq -e '.containers[0].exit_code==137' >/dev/null || fail "pod termination evidence lost"
probe_events my-ctx fixture pod | jq -e '.[0].reason=="BackOff"' >/dev/null || fail "events evidence lost"
probe_rollout my-ctx fixture deployment | jq -e '.unavailable==1' >/dev/null || fail "rollout evidence lost"
[ "$(probe_owner my-ctx fixture pod | wc -l | tr -d ' ')" -eq 2 ] || fail "owner chain lost"
[ "$(probe_logs_previous my-ctx fixture pod)" = 'fixture log line' ] || fail "successful log read lost"
kubectl() {
  case " $* " in *' get pod '*) printf '%s\n' '{"metadata":{"ownerReferences":[{"kind":"ReplicaSet","name":"fixture-rs"}]}}' ;; *) return 1 ;; esac
}
if out="$(probe_owner my-ctx fixture pod 2>/dev/null)"; then fail "failed second ownership read accepted"; fi
[ -z "$out" ] || fail "failed second ownership read emitted partial chain"

echo "Test 6b: failed provider reads cannot become successful empty jq projections"
kubectl() { printf '%s\n' '{"status":{"replicas":0},"metadata":{},"items":[]}'; return 1; }
for probe in probe_pod_status probe_events probe_rollout probe_owner probe_logs_previous; do
  if out="$("$probe" my-ctx fixture fixture 2>/dev/null)"; then fail "$probe accepted a failed provider read"; fi
  [ -z "$out" ] || fail "$probe emitted partial stdout from a failed provider read"
done
kubectl() { return 0; }
for probe in probe_pod_status probe_events probe_rollout; do
  if out="$("$probe" my-ctx fixture fixture 2>/dev/null)"; then fail "$probe accepted an empty successful response"; fi
done
unset -f kubectl

echo "Test 6: le_redact strips known secret shapes from a log slice"
red="$(printf 'user token AKIAIOSFODNN7EXAMPLE and Bearer %s\n' "$(printf 'a%.0s' $(seq 1 45))" | le_redact)"
printf '%s' "$red" | grep -q "AKIAIOSFODNN7EXAMPLE" && fail "le_redact left an AWS access key id in the output"
printf '%s' "$red" | grep -q "REDACTED" || fail "le_redact did not redact anything"
echo "PASS"

echo
echo "=== live-evidence lib self-test passed ==="
