#!/bin/sh
# IMP-003: audit-lgtm multi-cluster. The `lgtm:` block may be EITHER a single map
# (today — runtime_mode only; stores come from the top-level loki:/tempo:/... blocks;
# zero migration) OR a LIST of self-contained flat stack entries (multi-cluster).
# This locks the shared enumerator's behavior for that exact shape under BOTH the yq
# fast path and the no-yq awk fallback — the plan's highest-risk unknown (Task 1).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TT="$ROOT/report-standard/toolkit-targets.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; }
[ -f "$TT" ] || fail "toolkit-targets.sh missing"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

MULTI="$WORK/multi.yaml"
cat > "$MULTI" <<'YAML'
lgtm:
  - label: prod
    runtime_mode: kubernetes
    kubernetes_context: prod-ctx
    monitoring_namespace: monitoring
    loki_url: https://loki-prod.example.com
    victoriametrics_url: https://vm-prod.example.com
  - label: preprod
    runtime_mode: kubernetes
    kubernetes_context: preprod-ctx
    loki_url: https://loki-preprod.example.com
grafana:
  url: https://grafana.example.com
YAML

SINGLE="$WORK/single.yaml"
cat > "$SINGLE" <<'YAML'
lgtm:
  runtime_mode: kubernetes
kubernetes:
  context: my-ctx
loki:
  url: https://loki.example.com
YAML

# Run every assertion twice: once as-is (yq fast path if installed), once with a PATH
# that cannot see Homebrew/other yq (forces the awk fallback). Both MUST agree.
assert_multi() {
  mode="$1"; pfx="$2"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm kind")" = seq ] || fail "$mode: multi kind should be seq"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm count")" = 2 ] || fail "$mode: multi count should be 2"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm label 0")" = prod ] || fail "$mode: label 0 should be prod"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm label 1")" = preprod ] || fail "$mode: label 1 should be preprod"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm get 0 loki_url")" = "https://loki-prod.example.com" ] || fail "$mode: get 0 loki_url"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm get 1 loki_url")" = "https://loki-preprod.example.com" ] || fail "$mode: get 1 loki_url"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm get 0 kubernetes_context")" = "prod-ctx" ] || fail "$mode: get 0 kubernetes_context"
  [ "$(eval "$pfx sh \"$TT\" \"$MULTI\" lgtm get 0 runtime_mode")" = "kubernetes" ] || fail "$mode: get 0 runtime_mode"
  ok "$mode: multi seq (2 stacks, per-target flat keys resolve)"
}
assert_single() {
  mode="$1"; pfx="$2"
  [ "$(eval "$pfx sh \"$TT\" \"$SINGLE\" lgtm kind")" = map ] || fail "$mode: single kind should be map"
  [ "$(eval "$pfx sh \"$TT\" \"$SINGLE\" lgtm count")" = 1 ] || fail "$mode: single count should be 1"
  [ "$(eval "$pfx sh \"$TT\" \"$SINGLE\" lgtm label 0")" = lgtm ] || fail "$mode: single label 0 should default to 'lgtm'"
  [ "$(eval "$pfx sh \"$TT\" \"$SINGLE\" lgtm get 0 runtime_mode")" = kubernetes ] || fail "$mode: single get 0 runtime_mode"
  ok "$mode: single map (back-compat, label defaults to block name)"
}

assert_multi  "yq-or-native" ""
assert_single "yq-or-native" ""
# Force the awk fallback: a PATH with no yq.
assert_multi  "forced-awk" 'PATH=/usr/bin:/bin'
assert_single "forced-awk" 'PATH=/usr/bin:/bin'

echo "PASS: lgtm-multitarget (enumerator handles the lgtm stack-list, yq + awk, back-compat intact)"
