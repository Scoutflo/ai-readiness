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

# --- Interactive service selection ---
checkpoint_prompt_services() {
  printf "\n=== Select Services to Audit ===\n"
  printf "Available services: payment-svc, checkout-svc, analytics-svc, api-gateway\n"
  printf "Enter services (comma-separated, or 'all' for all): "
  read -r selection

  if [ "$selection" = "all" ] || [ -z "$selection" ]; then
    services="payment-svc,checkout-svc,analytics-svc,api-gateway"
  else
    services="$selection"
  fi

  echo "$services"
}

# --- Save scope to topology.json ---
checkpoint_save_scope() {
  services="$1"

  checkpoint_init_topology

  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  jq ".audit_scope = {
    services: (\"$services\" | split(\",\")),
    selected_at: \"$now\",
    revision: 1
  }" "$TOPOLOGY_FILE" > "$TOPOLOGY_FILE.tmp"

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
