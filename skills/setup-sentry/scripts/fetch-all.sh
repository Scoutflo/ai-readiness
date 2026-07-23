#!/bin/sh
# fetch-all.sh: $1 = full Sentry API URL. Follows Link-header cursor pagination
# and prints one merged JSON array. Requires SENTRY_TOKEN in the environment;
# the caller checks its presence before invoking this script (see
# ../references/api-cookbook.md#pagination-and-rate-limits).
set -eu

[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect" >&2; exit 1; }
[ -n "${1:-}" ] || { echo "usage: fetch-all.sh <full-api-url>" >&2; exit 1; }

fetch_all() {
  url="$1"; hdr="$(mktemp)"; acc="$(mktemp)"
  while [ -n "$url" ]; do
    curl -fsS --max-time 30 -H "Authorization: Bearer ${SENTRY_TOKEN}" -D "$hdr" "$url" >> "$acc" \
      || { rm -f "$hdr" "$acc"; return 1; }
    printf '\n' >> "$acc"
    url="$(tr -d '\r' < "$hdr" | sed -n 's/.*<\([^>]*\)>; rel="next"; results="true".*/\1/p')"
  done
  jq -s 'add // []' "$acc"
  rm -f "$hdr" "$acc"
}

fetch_all "$1"
