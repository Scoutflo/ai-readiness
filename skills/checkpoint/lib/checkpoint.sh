#!/bin/sh
# checkpoint.sh
# Interactive inventory selection + batching strategy

set -eu

TOPOLOGY_FILE="${HOME}/.scoutflo/topology.json"

# --- Initialize topology.json ---
checkpoint_init_topology() {
  if [ ! -f "$TOPOLOGY_FILE" ]; then
    mkdir -p "$(dirname "$TOPOLOGY_FILE")"
    echo '{}' | jq . > "$TOPOLOGY_FILE"
  fi
}

# --- Save scope to topology.json ---
# $1: comma-separated service names. "all" or empty clears the saved scope
# rather than storing "all" as a service name.
checkpoint_save_scope() {
  services="$1"

  checkpoint_init_topology

  case "$services" in
    ''|all) checkpoint_reset_scope; return 0 ;;
  esac

  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Names enter jq via --arg, never the program text: a quote or backslash in a
  # name must not break (or rewrite) the saved scope.
  jq --arg s "$services" --arg now "$now" '.audit_scope = {
    services: ($s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
    selected_at: $now,
    revision: 1
  }' "$TOPOLOGY_FILE" > "$TOPOLOGY_FILE.tmp"

  mv "$TOPOLOGY_FILE.tmp" "$TOPOLOGY_FILE"
}

# --- Get batch size based on resource count ---
checkpoint_get_batch_size() {
  count="$1"

  if [ "$count" -lt 100 ]; then
    echo "1"  # One pass
  elif [ "$count" -lt 500 ]; then
    echo "100"  # Batch by 100
  elif [ "$count" -lt 2000 ]; then
    echo "200"  # Batch by 200
  else
    echo "500"  # Batch by 500
  fi
}

# --- Batch resources ---
checkpoint_batch_resources() {
  total="$1"
  batch_size="$2"

  if [ "$batch_size" = "1" ]; then
    echo "1"  # One batch
    return 0
  fi

  # Calculate number of batches
  batches=$(( (total + batch_size - 1) / batch_size ))
  echo "$batches"
}

# --- Load scope from topology.json ---
checkpoint_load_scope() {
  checkpoint_init_topology

  scope=$(jq -r '.audit_scope.services[]? // empty' "$TOPOLOGY_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

  if [ -z "$scope" ]; then
    # Default to all if no scope set
    echo "all"
  else
    echo "$scope"
  fi
}

# --- Reset scope ---
checkpoint_reset_scope() {
  checkpoint_init_topology

  jq 'del(.audit_scope)' "$TOPOLOGY_FILE" > "$TOPOLOGY_FILE.tmp"
  mv "$TOPOLOGY_FILE.tmp" "$TOPOLOGY_FILE"
}
