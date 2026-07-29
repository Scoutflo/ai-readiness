#!/bin/sh
# business-context.sh
# Prompts user for business context, saves to topology.json

set -eu

TOPOLOGY_FILE="${HOME}/.scoutflo/topology.json"

# --- Initialize topology.json if missing ---
business_context_init_topology() {
  if [ ! -f "$TOPOLOGY_FILE" ]; then
    mkdir -p "$(dirname "$TOPOLOGY_FILE")"
    echo '{}' | jq . > "$TOPOLOGY_FILE"
  fi
}

# --- Prompt for all context fields ---
business_context_prompt() {
  printf "\n=== Scoutflo Business Context ===\n\n"

  # Team/Department
  printf "Team/Department name? "
  read -r team
  [ -z "$team" ] && { echo "Team name required"; return 1; }

  # Environment
  printf "Environment (staging/production/dr/dev)? "
  read -r environment
  case "$environment" in
    staging|production|dr|dev) ;;
    *) echo "Invalid environment: $environment"; return 1 ;;
  esac

  # SLA Uptime
  printf "SLA Uptime Target (e.g., 99.9, 99.99)? "
  read -r uptime_pct
  if ! echo "$uptime_pct" | grep -qE '^[0-9]+\.?[0-9]*$'; then
    echo "Invalid uptime: $uptime_pct"
    return 1
  fi

  # Cost Sensitivity
  printf "Cost Sensitivity (low/medium/high)? "
  read -r cost_sensitivity
  case "$cost_sensitivity" in
    low|medium|high) ;;
    *) echo "Invalid cost sensitivity: $cost_sensitivity"; return 1 ;;
  esac

  # Billing Owner
  printf "Billing Owner Email? "
  read -r billing_owner
  if ! echo "$billing_owner" | grep -qE '^[^@]+@[^@]+$'; then
    echo "Invalid email: $billing_owner"
    return 1
  fi

  # Save to topology.json
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  jq ".business_context = {
    team: \"$team\",
    environment: \"$environment\",
    sla: {
      uptime_percent: $uptime_pct,
      response_time_ms: 200,
      error_rate_percent: 0.01
    },
    cost_sensitivity: \"$cost_sensitivity\",
    billing_owner: \"$billing_owner\",
    critical_dependencies: [],
    updated_at: \"$now\",
    notes: \"\"
  }" "$TOPOLOGY_FILE" > "$TOPOLOGY_FILE.tmp"

  mv "$TOPOLOGY_FILE.tmp" "$TOPOLOGY_FILE"

  echo "[saved] Business context updated for $team in $environment"
}

# --- Load business context from topology.json ---
business_context_load() {
  business_context_init_topology

  if [ ! -f "$TOPOLOGY_FILE" ]; then
    echo "{}"
    return 0
  fi

  jq '.business_context // {}' "$TOPOLOGY_FILE"
}

# --- Get field from business context ---
business_context_get() {
  field="$1"

  context=$(business_context_load)

  echo "$context" | jq -r ".$field // empty" 2>/dev/null || echo ""
}
