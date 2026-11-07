#!/bin/sh
# Resolve from config afresh in every shell; never accept an inherited context.
set -eu
set +x
: "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}"
. "$CLAUDE_PLUGIN_ROOT/skills/redaction/lib/redaction.sh"
. "$CLAUDE_PLUGIN_ROOT/skills/live-evidence/lib/live-evidence.sh"
CFG=${SCOUTFLO_CONFIG:-}
if [ -z "$CFG" ]; then
  for rca_cfg in ./.scoutflo/toolkit.yaml "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    if [ -f "$rca_cfg" ]; then CFG=$rca_cfg; break; fi
  done
fi
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'RCA live branch: no selected config' >&2; return 1; }
TT="$CLAUDE_PLUGIN_ROOT/report-standard/toolkit-targets.sh"
RCA_K8S_N=$(sh "$TT" "$CFG" kubernetes count)
[ "$RCA_K8S_N" -gt 0 ] || { echo 'RCA live branch: no configured cluster' >&2; return 1; }
RCA_K8S_KIND=$(sh "$TT" "$CFG" kubernetes kind)
[ "$RCA_K8S_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'RCA live branch: select a cluster label' >&2; return 1; }
KUBE_CONTEXT=; RCA_LIVE_TARGET=; rca_i=0; rca_matches=0
while [ "$rca_i" -lt "$RCA_K8S_N" ]; do
  rca_label=$(sh "$TT" "$CFG" kubernetes label "$rca_i")
  if [ "$RCA_K8S_KIND" != seq ] || [ "$rca_label" = "${SCOUTFLO_TARGET:-}" ]; then
    KUBE_CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$rca_i" context)
    RCA_LIVE_TARGET="kubernetes/$rca_label"; rca_matches=$((rca_matches+1))
  fi
  rca_i=$((rca_i+1))
done
[ "$rca_matches" -eq 1 ] && [ -n "$KUBE_CONTEXT" ] || { echo 'RCA live branch: target must match one configured cluster' >&2; return 1; }
# Single-block Kubernetes exports use the configured context as the target path.
[ "$RCA_K8S_KIND" = seq ] || RCA_LIVE_TARGET="kubernetes/$KUBE_CONTEXT"
[ "${RCA_TARGET:-$RCA_LIVE_TARGET}" = "$RCA_LIVE_TARGET" ] || { echo 'RCA live branch: report and cluster target differ; resolve the specific workload first' >&2; return 1; }
command -v kubectl >/dev/null || return 1
# The reviewed endpoint is a nonsecret identity expectation, not copied from this read.
: "${RCA_EXPECTED_SERVER:?Set the independently reviewed API endpoint for this cluster}"
rca_config=$(le_read_json "$KUBE_CONTEXT" config view --minify -o json) || return 1
printf '%s' "$rca_config" | jq -e --arg expected "$RCA_EXPECTED_SERVER" '(.clusters|length)==1 and .clusters[0].cluster.server==$expected' >/dev/null || { echo 'RCA live branch: server identity mismatch' >&2; return 1; }
le_can_probe "$KUBE_CONTEXT" || return 1
rca_version=$(le_read_json "$KUBE_CONTEXT" version -o json) || return 1
printf '%s' "$rca_version" | jq -e '.serverVersion.gitVersion|type=="string" and length>0' >/dev/null || { echo 'RCA live branch: no server version proof' >&2; return 1; }
printf 'Verified selected live target: %s\n' "$RCA_LIVE_TARGET"
