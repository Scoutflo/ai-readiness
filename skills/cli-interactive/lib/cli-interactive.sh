#!/bin/sh
# cli-interactive.sh
# Interactive CLI confirmations before operations

set -eu

# --- Pause before big operation ---
cli_pause_before_audit() {
  resource_count="$1"

  if [ "$resource_count" -lt 1000 ]; then
    return 0  # Don't pause for small audits
  fi

  printf "\n⚠️  About to audit %d+ resources. Continue? (y/n) " "$resource_count"
  read -r response

  case "$response" in
    y|Y|yes|YES) return 0 ;;
    *) echo "Audit cancelled."; exit 0 ;;
  esac
}

# --- Prompt to exclude services ---
cli_prompt_exclude_services() {
  printf "\nServices to exclude? (comma-separated, or press enter to skip): "
  read -r excluded

  if [ -z "$excluded" ]; then
    echo ""
  else
    echo "$excluded"
  fi
}

# --- Prompt to exclude regions ---
cli_prompt_exclude_regions() {
  printf "\nRegions to exclude? (comma-separated, or press enter to skip): "
  read -r excluded

  if [ -z "$excluded" ]; then
    echo ""
  else
    echo "$excluded"
  fi
}

# --- Prompt to exclude statuses ---
cli_prompt_exclude_statuses() {
  printf "\nStatuses to exclude? (comma-separated: stopped,terminated,pending): "
  read -r excluded

  if [ -z "$excluded" ]; then
    echo ""
  else
    echo "$excluded"
  fi
}

# --- Build exclusion filter ---
cli_build_exclusion_filter() {
  services="$1"
  regions="$2"
  statuses="$3"

  filter=""

  if [ -n "$services" ]; then
    filter="$filter --exclude-services=$services"
  fi

  if [ -n "$regions" ]; then
    filter="$filter --exclude-regions=$regions"
  fi

  if [ -n "$statuses" ]; then
    filter="$filter --exclude-statuses=$statuses"
  fi

  echo "$filter"
}

# --- Confirm before proceeding ---
cli_confirm_proceed() {
  message="$1"

  printf "\n%s Proceed? (y/n) " "$message"
  read -r response

  case "$response" in
    y|Y|yes|YES) return 0 ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
}
