#!/bin/sh
# Execute actual published check blocks with synthetic, local-only Kubernetes
# responses. Boolean precedence and network-policy semantics are customer output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TEST_SHELL=${K8S_TEST_SHELL:-/bin/sh}
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
HOME="$TASK_TMP/home"; CLAUDE_PLUGIN_ROOT="$ROOT"; SCOUTFLO_CONFIG="$TASK_TMP/config.yaml"
SCOUTFLO_AUDIT_DIR="$TASK_TMP/audits"; SCOUTFLO_ENV_FILE="$TASK_TMP/access.env"
export HOME CLAUDE_PLUGIN_ROOT SCOUTFLO_CONFIG SCOUTFLO_AUDIT_DIR SCOUTFLO_ENV_FILE
unset KUBECONFIG SCOUTFLO_TARGET SCOUTFLO_K8S_RUN_ID
mkdir -p "$HOME" "$TASK_TMP/bin"
PATH="$TASK_TMP/bin:$PATH"; export PATH
STUB_PODS="$TASK_TMP/pods.json"; STUB_SAS="$TASK_TMP/sa.json"; STUB_NPS="$TASK_TMP/np.json"
STUB_KUBECONFIG="$TASK_TMP/chosen-kubeconfig"; STUB_LOG="$TASK_TMP/calls.log"
export STUB_PODS STUB_SAS STUB_NPS STUB_KUBECONFIG STUB_LOG
printf 'kubernetes:\n  context: example-context\n' > "$SCOUTFLO_CONFIG"
printf 'export KUBECONFIG="%s"\n' "$STUB_KUBECONFIG" > "$SCOUTFLO_ENV_FILE"
printf '#!/bin/sh\nexit 1\n' > "$TASK_TMP/bin/yq"
cat > "$TASK_TMP/bin/kubectl" <<'STUB'
#!/bin/sh
[ "$1" = --context ] && [ "$2" = example-context ] && [ "$3" = --request-timeout=30s ] && [ "$4" = get ] || exit 90
[ "${KUBECONFIG:-}" = "$STUB_KUBECONFIG" ] || { echo 'fixture: stored kubeconfig not loaded' >&2; exit 91; }
printf '%s\n' "$5" >> "$STUB_LOG"
[ "${STUB_DENY:-}" != "$5" ] || { echo 'Forbidden: fixture read denied' >&2; exit 1; }
[ "${STUB_EMPTY:-}" != "$5" ] || exit 0
case "$5" in
  pods) cat "$STUB_PODS" ;;
  serviceaccounts) cat "$STUB_SAS" ;;
  networkpolicies) cat "$STUB_NPS" ;;
  namespaces) printf '%s\n' '{"items":[{"metadata":{"name":"app"}},{"metadata":{"name":"other"}}]}' ;;
  pods,*) cat "$STUB_PODS" ;;
  *) exit 92 ;;
esac
STUB
chmod +x "$TASK_TMP/bin/kubectl" "$TASK_TMP/bin/yq"
fail() { echo "FAIL: $*" >&2; exit 1; }
extract() {
  awk -v id="$1" '$0 ~ "^### " id " " {section=1;next} section && /^```bash$/{block=1;next} block && /^```$/{exit} block{print}' \
    "$ROOT/skills/audit-kubernetes/references/kubernetes-checks.md" > "$TASK_TMP/$1.sh"
  [ -s "$TASK_TMP/$1.sh" ] || fail "missing check $1"
}
for id in K8S-003 K8S-008 K8S-009 K8S-011; do extract "$id"; done
check() { "$TEST_SHELL" "$TASK_TMP/$1.sh"; }

echo 'Test 1: effective container hardening preserves false and container-over-Pod precedence'
jq -n '
  {name:"web",securityContext:{runAsNonRoot:true,readOnlyRootFilesystem:true,allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]}}} as $safe |
  {items:[
    {kind:"Pod",metadata:{namespace:"app",name:"safe"},spec:{containers:[$safe]}},
    {kind:"Pod",metadata:{namespace:"app",name:"container-false"},spec:{securityContext:{runAsNonRoot:true},containers:[($safe|.securityContext.runAsNonRoot=false)]}},
    {kind:"Pod",metadata:{namespace:"app",name:"container-true"},spec:{securityContext:{runAsNonRoot:false},containers:[$safe]}},
    {kind:"Pod",metadata:{namespace:"app",name:"inherit-true"},spec:{securityContext:{runAsNonRoot:true},containers:[($safe|del(.securityContext.runAsNonRoot))]}},
    {kind:"Pod",metadata:{namespace:"app",name:"unset"},spec:{containers:[($safe|del(.securityContext.allowPrivilegeEscalation))]}}
  ]}' > "$STUB_PODS"
check K8S-008 > "$TASK_TMP/output"
[ "$(wc -l < "$TASK_TMP/output" | tr -d ' ')" = 2 ] || fail 'safe container falsely flagged or real defect missed'
grep -q 'container-false.*runAsNonRoot=false.*allowPrivEsc=false' "$TASK_TMP/output" || fail 'explicit container false hidden or false rendered unset'
grep -q 'unset.*allowPrivEsc=unset' "$TASK_TMP/output" || fail 'missing allowPrivilegeEscalation not detected'
echo PASS

echo 'Test 2: Pod automount override, SA inheritance, defaults, and unknown SA are distinct'
jq -n '{items:[
 {metadata:{namespace:"app",name:"pod-disabled"},spec:{serviceAccountName:"enabled",automountServiceAccountToken:false}},
 {metadata:{namespace:"app",name:"sa-disabled"},spec:{serviceAccountName:"disabled"}},
 {metadata:{namespace:"app",name:"pod-enabled"},spec:{serviceAccountName:"disabled",automountServiceAccountToken:true}},
 {metadata:{namespace:"app",name:"default-enabled"},spec:{}},
 {metadata:{namespace:"app",name:"unknown-sa"},spec:{serviceAccountName:"missing"}}
]}' > "$STUB_PODS"
printf '%s\n' '{"items":[{"metadata":{"namespace":"app","name":"enabled"},"automountServiceAccountToken":true},{"metadata":{"namespace":"app","name":"disabled"},"automountServiceAccountToken":false},{"metadata":{"namespace":"app","name":"default"}}]}' > "$STUB_SAS"
check K8S-009 > "$TASK_TMP/output"
[ "$(wc -l < "$TASK_TMP/output" | tr -d ' ')" = 3 ] || fail 'effective automount rows wrong'
! grep -q 'pod-disabled\|sa-disabled' "$TASK_TMP/output" || fail 'disabled token mount flagged'
grep -q 'pod-enabled.*effectiveAutomount=true' "$TASK_TMP/output" || fail 'Pod true did not override SA false'
grep -q 'default-enabled.*effectiveAutomount=true' "$TASK_TMP/output" || fail 'default enabled mount omitted'
grep -q 'unknown-sa.*effectiveAutomount=unknown' "$TASK_TMP/output" || fail 'missing SA became verified true'
echo PASS

echo 'Test 3: allow-all, label and expression selectors are never default-deny baselines'
jq -n '{items:[
 {metadata:{namespace:"deny"},spec:{podSelector:{},policyTypes:["Ingress"],ingress:[]}},
 {metadata:{namespace:"deny-default-types"},spec:{podSelector:{}}},
 {metadata:{namespace:"allow-all"},spec:{podSelector:{},policyTypes:["Ingress"],ingress:[{}]}},
 {metadata:{namespace:"expressions"},spec:{podSelector:{matchExpressions:[{key:"app",operator:"In",values:["web"]}]},policyTypes:["Ingress"],ingress:[]}},
 {metadata:{namespace:"labels"},spec:{podSelector:{matchLabels:{app:"web"}},policyTypes:["Ingress"],ingress:[]}},
 {metadata:{namespace:"egress-only"},spec:{podSelector:{},policyTypes:["Egress"],egress:[]}}
]}' > "$STUB_NPS"
check K8S-011 > "$TASK_TMP/output"
printf 'deny\ndeny-default-types\n' > "$TASK_TMP/expected"
cmp -s "$TASK_TMP/expected" "$TASK_TMP/output" || fail 'false default-deny baseline'
echo PASS

echo 'Test 4: denied or malformed reads are blocked, not a clean empty result'
for pair in K8S-003:networkpolicies K8S-003:namespaces K8S-008:pods K8S-009:serviceaccounts K8S-011:networkpolicies; do
  STUB_DENY=${pair#*:}; export STUB_DENY
  if check "${pair%:*}" > "$TASK_TMP/output" 2> "$TASK_TMP/error"; then fail "denied read passed: $pair"; fi
  grep -q blocked "$TASK_TMP/error" || fail 'denied read lacks blocked explanation'
done
unset STUB_DENY
printf '%s\n' '{"items":[{"metadata":{"namespace":"app"}}]}' > "$STUB_NPS"
[ "$(check K8S-003)" = other ] || fail 'successful namespace coverage difference is wrong'
printf '{"unexpected":[]}' > "$STUB_NPS"
if check K8S-003 > "$TASK_TMP/output" 2> "$TASK_TMP/error"; then fail 'malformed policy list became a missing-policy finding'; fi
if check K8S-011 > "$TASK_TMP/output" 2> "$TASK_TMP/error"; then fail 'malformed policy list passed'; fi
for pair in K8S-003:namespaces K8S-003:networkpolicies K8S-008:pods K8S-009:serviceaccounts K8S-011:networkpolicies; do
  STUB_EMPTY=${pair#*:}; export STUB_EMPTY
  if check "${pair%:*}" > "$TASK_TMP/output" 2> "$TASK_TMP/error"; then fail "empty successful read passed: $pair"; fi
  grep -q blocked "$TASK_TMP/error" || fail 'empty read lacks blocked explanation'
done
unset STUB_EMPTY
for invalid in '{broken' '{"items":[]} {"items":[]}' '[]'; do
  printf '%s\n' "$invalid" > "$STUB_NPS"
  if sh "$ROOT/skills/audit-kubernetes/scripts/run-state.sh" read-list networkpolicies > "$TASK_TMP/output" 2> "$TASK_TMP/error"; then fail 'invalid or multiple response passed the central List guard'; fi
done
printf '%s\n' '{"items":[]}' > "$STUB_NPS"
sh "$ROOT/skills/audit-kubernetes/scripts/run-state.sh" read-list networkpolicies > "$TASK_TMP/output"
jq -e '.items==[]' "$TASK_TMP/output" >/dev/null || fail 'verified empty List was rejected'
echo PASS

echo 'Test 5: persisted sizing reloads a store-only kubeconfig in a fresh shell'
printf '%s\n' '{"items":[{"kind":"Pod","metadata":{"namespace":"app","name":"web"}}]}' > "$STUB_PODS"
sh "$ROOT/skills/audit-kubernetes/scripts/run-state.sh" size >/dev/null
[ -s "$STUB_LOG" ] || fail 'no stub was called'
[ "${KUBECONFIG-unset}" = unset ] || fail 'test accidentally exported kubeconfig into the caller'
echo PASS
echo 'Test 6: secret-store exports cannot override caller target, config, run or output routing'
cat > "$SCOUTFLO_CONFIG" <<'CFG'
kubernetes:
  - label: east
    context: example-context
  - label: west
    context: wrong-context
CFG
SCOUTFLO_TARGET=east; export SCOUTFLO_TARGET
cat >> "$SCOUTFLO_ENV_FILE" <<EOF
export SCOUTFLO_TARGET=west
export SCOUTFLO_CONFIG="$TASK_TMP/nonexistent.yaml"
export SCOUTFLO_AUDIT_DIR="$TASK_TMP/store-output"
export SCOUTFLO_K8S_RUN_ID=wrong-run
EOF
sh "$ROOT/skills/audit-kubernetes/scripts/run-state.sh" size >/dev/null
jq -e '.target=="kubernetes/east" and .context=="example-context"' "$SCOUTFLO_AUDIT_DIR/kubernetes/east/sizing.json" >/dev/null || fail 'store redirected the selected target'
[ ! -d "$TASK_TMP/store-output" ] || fail 'store redirected the output directory'
echo PASS
echo 'Kubernetes posture predicates: 6 cases passed'
