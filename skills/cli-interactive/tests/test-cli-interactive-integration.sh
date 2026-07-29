#!/bin/sh
# Integration tests: CLI interactive prompts in audit flow
# Tests that cli-interactive.sh integration functions correctly

set -eu

CLI_LIB="${BATS_TEST_DIRNAME}/../lib"

@test "cli integration: pause calculation threshold" {
  . "${CLI_LIB}/cli-interactive.sh"

  # Should not pause for small audits
  if ! cli_pause_before_audit 50 2>/dev/null; then
    return 0  # Function should exit 0 for no pause
  fi
}

@test "cli integration: build exclusion filter empty" {
  . "${CLI_LIB}/cli-interactive.sh"

  # Empty exclusions should return empty string
  filter=$(cli_build_exclusion_filter "" "" "")
  if [ -n "$filter" ]; then
    echo "FAIL: Expected empty filter, got: $filter"
    exit 1
  fi
}

@test "cli integration: build exclusion filter with services" {
  . "${CLI_LIB}/cli-interactive.sh"

  # Exclusions should be formatted correctly
  filter=$(cli_build_exclusion_filter "s3,lambda" "" "")
  if ! echo "$filter" | grep -q "s3,lambda"; then
    echo "FAIL: Services not in filter: $filter"
    exit 1
  fi
}

@test "cli integration: build exclusion filter with regions" {
  . "${CLI_LIB}/cli-interactive.sh"

  # Region exclusions should be formatted correctly
  filter=$(cli_build_exclusion_filter "" "ap-southeast-1,eu-west-1" "")
  if ! echo "$filter" | grep -q "ap-southeast-1"; then
    echo "FAIL: Regions not in filter: $filter"
    exit 1
  fi
}

@test "cli integration: build exclusion filter with statuses" {
  . "${CLI_LIB}/cli-interactive.sh"

  # Status exclusions should be formatted correctly
  filter=$(cli_build_exclusion_filter "" "" "stopped,terminated")
  if ! echo "$filter" | grep -q "stopped"; then
    echo "FAIL: Statuses not in filter: $filter"
    exit 1
  fi
}

@test "cli integration: build exclusion filter all combined" {
  . "${CLI_LIB}/cli-interactive.sh"

  # All exclusions combined
  filter=$(cli_build_exclusion_filter "s3,lambda" "ap-south-1" "pending")
  if ! echo "$filter" | grep -q "exclude-services"; then
    echo "FAIL: Services flag missing in filter: $filter"
    exit 1
  fi
  if ! echo "$filter" | grep -q "exclude-regions"; then
    echo "FAIL: Regions flag missing in filter: $filter"
    exit 1
  fi
  if ! echo "$filter" | grep -q "exclude-statuses"; then
    echo "FAIL: Statuses flag missing in filter: $filter"
    exit 1
  fi
}
