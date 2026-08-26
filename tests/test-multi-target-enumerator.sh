#!/bin/sh
# test-multi-target-enumerator.sh — regression lock for report-standard/toolkit-targets.sh,
# the shared multi-target ("multiple targets under one integration") config enumerator.
# Verifies: single-block mappings behave exactly like the old two-level read (1 target,
# label = block name), a YAML list yields N labeled targets, values are stripped of quotes
# and trailing comments, and an absent block yields 0. Runs under /bin/sh via ci/run-tests.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TT="$ROOT/report-standard/toolkit-targets.sh"
[ -f "$TT" ] || { echo "FAIL: missing $TT"; exit 1; }

FIX=$(mktemp); trap 'rm -f "$FIX"' EXIT INT TERM
cat > "$FIX" <<'YAML'
clickstack:
  - label: hdx-eu
    hyperdx_url: https://eu:8080
    hyperdx_api_key_env: HDX_EU_KEY
  - label: hdx-us
    hyperdx_url: https://us:8080   # trailing comment must be stripped
    hyperdx_api_key_env: HDX_US_KEY
azure:
  subscription_id: "0000-single"
  tier: read-only
YAML

FAIL=0
eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok: %s\n' "$1"
  else printf '  FAIL: %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; FAIL=1; fi
}
t() { sh "$TT" "$FIX" "$@"; }

echo "multi-target list (clickstack, 3-ish):"
eq "count=2"            2                    "$(t clickstack count)"
eq "label0=hdx-eu"      hdx-eu               "$(t clickstack label 0)"
eq "label1=hdx-us"      hdx-us               "$(t clickstack label 1)"
eq "get0 url"           https://eu:8080      "$(t clickstack get 0 hyperdx_url)"
eq "get0 key_env"       HDX_EU_KEY           "$(t clickstack get 0 hyperdx_api_key_env)"
eq "get1 url (comment stripped)" https://us:8080 "$(t clickstack get 1 hyperdx_url)"
eq "get1 key_env"       HDX_US_KEY           "$(t clickstack get 1 hyperdx_api_key_env)"

echo "single-block mapping (azure) behaves like the old read:"
eq "count=1"            1                    "$(t azure count)"
eq "label0=azure"       azure                "$(t azure label 0)"
eq "get0 sub (quotes stripped)" 0000-single  "$(t azure get 0 subscription_id)"
eq "get0 tier"          read-only            "$(t azure get 0 tier)"

echo "kind (drives the flat-vs-nested output path rule):"
eq "clickstack kind=seq" seq                 "$(t clickstack kind)"
eq "azure kind=map"      map                  "$(t azure kind)"
eq "sentry kind=absent"  absent               "$(t sentry kind)"

echo "absent block:"
eq "count=0"            0                    "$(t sentry count)"

if [ "$FAIL" -ne 0 ]; then echo "MULTI-TARGET-ENUMERATOR: FAILED"; exit 1; fi
echo "MULTI-TARGET-ENUMERATOR: OK"
