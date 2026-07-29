#!/bin/sh
# Integration tests: checkpoint persistence in audit flow
# Tests that checkpoint.sh scope selection and batching works

set -eu

CHECKPOINT_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_TOPOLOGY="/tmp/.scoutflo/topology-cp-test.json"
export HOME="/tmp"
export TOPOLOGY_FILE="$TEST_TOPOLOGY"

setup() {
  mkdir -p "$(dirname "$TEST_TOPOLOGY")"
  rm -f "$TEST_TOPOLOGY" "$TEST_TOPOLOGY.bak"
}

teardown() {
  rm -f "$TEST_TOPOLOGY" "$TEST_TOPOLOGY.bak"
}

@test "checkpoint integration: init creates topology file" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  checkpoint_init_topology

  [ -f "$TEST_TOPOLOGY" ]
}

@test "checkpoint integration: save and load scope" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  checkpoint_init_topology

  # Save a scope
  checkpoint_save_scope "payment-svc,checkout-svc,api-gateway"

  # Load it back
  loaded=$(checkpoint_load_scope)

  if ! echo "$loaded" | grep -q "payment-svc"; then
    echo "FAIL: payment-svc not in loaded scope"
    exit 1
  fi
}

@test "checkpoint integration: batch size calculation small" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # < 100 resources = 1 batch
  size=$(checkpoint_get_batch_size 50)
  [ "$size" = "1" ]
}

@test "checkpoint integration: batch size calculation medium" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # 100-500 resources = batch by 100
  size=$(checkpoint_get_batch_size 250)
  [ "$size" = "100" ]
}

@test "checkpoint integration: batch size calculation large" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # 500-2000 resources = batch by 200
  size=$(checkpoint_get_batch_size 1500)
  [ "$size" = "200" ]
}

@test "checkpoint integration: batch size calculation xlarge" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # > 2000 resources = batch by 500
  size=$(checkpoint_get_batch_size 5000)
  [ "$size" = "500" ]
}

@test "checkpoint integration: batch count calculation" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # 1500 resources at 200/batch = 8 batches
  count=$(checkpoint_batch_resources 1500 200)
  [ "$count" = "8" ]
}

@test "checkpoint integration: batch count one" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # 50 resources at 1/batch = 1 batch
  count=$(checkpoint_batch_resources 50 1)
  [ "$count" = "1" ]
}

@test "checkpoint integration: default scope when not set" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  checkpoint_init_topology

  # No scope saved yet
  loaded=$(checkpoint_load_scope)

  # Should default to "all"
  [ "$loaded" = "all" ]
}

@test "checkpoint integration: reset scope" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  checkpoint_init_topology

  # Save a scope
  checkpoint_save_scope "payment-svc,checkout-svc"

  # Reset it
  checkpoint_reset_scope

  # Should now default to "all"
  loaded=$(checkpoint_load_scope)
  [ "$loaded" = "all" ]
}

@test "checkpoint integration: persist scope across sessions" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  checkpoint_init_topology

  # Save scope in first "session"
  checkpoint_save_scope "analytics-svc,reporting-svc"

  # Unset function to simulate new session
  unset checkpoint_load_scope

  # Reload
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # Should still load the saved scope
  loaded=$(checkpoint_load_scope)
  if ! echo "$loaded" | grep -q "analytics-svc"; then
    echo "FAIL: Scope not persisted across sessions"
    exit 1
  fi
}

@test "checkpoint integration: full scenario 1500 resources" {
  . "${CHECKPOINT_LIB}/checkpoint.sh"

  # Simulate full flow: detect 1500 resources, calculate batch strategy
  resource_count=1500
  batch_size=$(checkpoint_get_batch_size "$resource_count")
  batch_count=$(checkpoint_batch_resources "$resource_count" "$batch_size")

  # 1500 / 200 = 8 batches of 200
  [ "$batch_size" = "200" ]
  [ "$batch_count" = "8" ]
}
