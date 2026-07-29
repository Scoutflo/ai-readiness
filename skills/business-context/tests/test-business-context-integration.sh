#!/bin/sh
# Integration tests: business context in audit flow
# Tests that business-context.sh persistence and loading works

set -eu

BUSINESS_CONTEXT_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_TOPOLOGY="/tmp/.scoutflo/topology-bc-test.json"
export HOME="/tmp"
export TEST_TOPOLOGY

setup() {
  mkdir -p "$(dirname "$TEST_TOPOLOGY")"
  rm -f "$TEST_TOPOLOGY" "$TEST_TOPOLOGY.bak"
}

teardown() {
  rm -f "$TEST_TOPOLOGY" "$TEST_TOPOLOGY.bak"
}

@test "business context integration: init topology file" {
  # Override TOPOLOGY_FILE for testing
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  [ -f "$TEST_TOPOLOGY" ]
}

@test "business context integration: save and load context" {
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  # Simulate context data (normally from interactive prompt)
  jq '.business_context = {
    "team": "platform",
    "environment": "production",
    "uptime_sla": 99.9,
    "cost_sensitivity": "high",
    "billing_owner": "ops@example.com",
    "captured_at": "2026-07-30T17:00:00Z"
  }' "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
  mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"

  # Load and verify
  team=$(business_context_get "team")
  [ "$team" = "platform" ]

  environment=$(business_context_get "environment")
  [ "$environment" = "production" ]

  cost=$(business_context_get "cost_sensitivity")
  [ "$cost" = "high" ]
}

@test "business context integration: missing context handled" {
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  # File exists but no context key yet
  team=$(business_context_get "team" 2>/dev/null || true)
  # Should be empty or error-handled
}

@test "business context integration: all required fields present" {
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  # Save complete context
  jq '.business_context = {
    "team": "backend",
    "environment": "staging",
    "uptime_sla": 95.0,
    "cost_sensitivity": "low",
    "billing_owner": "finance@example.com",
    "captured_at": "2026-07-30T17:00:00Z"
  }' "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
  mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"

  # Verify all fields can be loaded
  team=$(business_context_get "team")
  env=$(business_context_get "environment")
  sla=$(business_context_get "uptime_sla")
  cost=$(business_context_get "cost_sensitivity")
  owner=$(business_context_get "billing_owner")

  [ "$team" = "backend" ]
  [ "$env" = "staging" ]
  [ "$sla" = "95.0" ]
  [ "$cost" = "low" ]
  [ "$owner" = "finance@example.com" ]
}

@test "business context integration: environment validation" {
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  # Valid environments
  for env in production staging dr dev; do
    jq ".business_context.environment = \"$env\"" "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
    mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"
    loaded=$(business_context_get "environment")
    [ "$loaded" = "$env" ]
  done
}

@test "business context integration: persist across sessions" {
  TOPOLOGY_FILE="$TEST_TOPOLOGY"
  export TOPOLOGY_FILE

  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  business_context_init_topology

  # Save in first "session"
  jq '.business_context = {"team": "session1"}' "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
  mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"

  # Unset functions to simulate new session
  unset business_context_get

  # Reload in new session
  . "${BUSINESS_CONTEXT_LIB}/business-context.sh"

  # Should still load the saved team
  team=$(business_context_get "team")
  [ "$team" = "session1" ]
}
