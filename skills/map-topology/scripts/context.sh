#!/bin/sh
# Source in every fresh Kubernetes recipe. Config names are metadata, never eval.
map_context() {
  : "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}"
  CFG=${SCOUTFLO_CONFIG:-}
  [ -n "$CFG" ] || for _map_cfg in ./.scoutflo/toolkit.yaml "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$_map_cfg" ] && { CFG=$_map_cfg; break; }
  done
  [ -f "$CFG" ] || { echo 'Topology config missing; run /scoutflo:connect' >&2; return 1; }
  TT="$CLAUDE_PLUGIN_ROOT/report-standard/toolkit-targets.sh"
  K8S_N=$(sh "$TT" "$CFG" kubernetes count)
  [ "${K8S_N:-0}" -ge 1 ] || { echo 'No Kubernetes target configured; use the non-Kubernetes source path' >&2; return 1; }
  K8S_KIND=$(sh "$TT" "$CFG" kubernetes kind)
  K8S_IDX=0
  if [ "$K8S_KIND" = seq ]; then
    [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select SCOUTFLO_TARGET for a labeled Kubernetes list; never default to its first cluster' >&2; return 1; }
    _map_found=0; _map_i=0
    while [ "$_map_i" -lt "$K8S_N" ]; do
      [ "$(sh "$TT" "$CFG" kubernetes label "$_map_i")" != "$SCOUTFLO_TARGET" ] || { K8S_IDX=$_map_i; _map_found=$((_map_found+1)); }
      _map_i=$((_map_i+1))
    done
    [ "$_map_found" -eq 1 ] || { echo 'Selected Kubernetes label must match exactly one configured target' >&2; return 1; }
    : "${SCOUTFLO_AUDIT_DIR:?Set the selected cluster audit directory}"
  fi
  K8S_LABEL=$(sh "$TT" "$CFG" kubernetes label "$K8S_IDX")
  KUBE_CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$K8S_IDX" context)
  [ -n "$KUBE_CONTEXT" ] || { echo 'Selected Kubernetes context is empty' >&2; return 1; }
  MAP_TARGET=kubernetes
  [ "$K8S_KIND" != seq ] || MAP_TARGET="kubernetes/$K8S_LABEL"
  map_paths
  export KUBE_CONTEXT MAP_TARGET NS_EXCLUDE
}
map_paths() {
  MAP_ROOT=${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}
  NS_EXCLUDE=${SCOUTFLO_NAMESPACE_EXCLUDE:-'^(kube-system|kube-public|kube-node-lease|istio-system)$'}
  TMP=${SCOUTFLO_TOPOLOGY_WORK_DIR:-"$MAP_ROOT/map-topology/$(date -u +%F)"}
  umask 077
  mkdir -p "$TMP"
  export MAP_ROOT NS_EXCLUDE TMP
}
map_get() { python3 "$CLAUDE_PLUGIN_ROOT/skills/map-topology/lib/topology-read.py" get "$@"; }
map_run() { python3 "$CLAUDE_PLUGIN_ROOT/skills/map-topology/lib/worklist.py" "$@"; }
