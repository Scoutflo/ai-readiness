#!/bin/sh
# optional-key-parity-check.sh (contract C15)
# The per-provider REQUIRED-vs-OPTIONAL config-key contract, made explicit and
# template-enforced, so the "the setup surface calls a key optional but the audit
# hard-requires it" drift class — the ClickStack HyperDX-only blocker — cannot
# silently recur. Block-level config-key-agreement only checks that block NAMES
# agree across doctor/template; it does NOT see sub-key optionality. This gate is
# the executable SSOT for that.
#
# For each provider it declares one of:
#   req   <provider> <key...>   -- each key MUST appear UNCOMMENTED in the provider's
#                                  template block (a genuinely required key)
#   oneof <provider> <key...>   -- AT LEAST ONE must appear UNCOMMENTED (an either-or
#                                  lane contract, e.g. ClickStack = ClickHouse OR HyperDX)
# and asserts templates/toolkit.yaml.example matches. A key that is neither req nor
# in a oneof is unconstrained (genuinely optional; commented or absent is fine).
#
# SCOPE (honest): this locks the operator-facing declaration + the template so they
# cannot drift from the contract. It does NOT parse each audit's doctor-gate bash to
# auto-detect a hard-stop (too fragile); that side stays the skill's own behavior +
# the maintainer review. But the declaration below IS the reference both must match,
# and the ClickStack `oneof` here is exactly what would have flagged the original bug
# (the audit hard-required ClickHouse while this contract says one lane suffices).
#
# Read-only. POSIX sh + awk + grep.
set -eu
DIR="${1:-.}"
T="$DIR/templates/toolkit.yaml.example"
[ -f "$T" ] || { echo "OPTIONAL-KEY-PARITY: templates/toolkit.yaml.example missing" >&2; exit 1; }
FAIL=0

# Print a provider's block: from the top-level `^<name>:` line to the next top-level key.
block() {
  awk -v p="^$1:" '
    $0 ~ p {a=1; print; next}
    a && /^[a-z_]/ {exit}
    a {print}
  ' "$T"
}
# True when <key> appears UNCOMMENTED (indented `  key:`, not `  # key:`) on stdin.
has_uncommented() { grep -Eq "^[[:space:]]+$1:"; }

req() {
  _p="$1"; shift; _b="$(block "$_p")"
  [ -n "$_b" ] || { echo "OPTIONAL-KEY-PARITY: provider '$_p' has no block in the template" >&2; FAIL=1; return; }
  for _k in "$@"; do
    printf '%s\n' "$_b" | has_uncommented "$_k" \
      || { echo "OPTIONAL-KEY-PARITY: $_p.$_k is declared REQUIRED but is not present uncommented in the template block — add it, or move it to an oneof/optional if the audit no longer requires it" >&2; FAIL=1; }
  done
}
oneof() {
  _p="$1"; shift; _b="$(block "$_p")"; _ok=0; _keys="$*"
  [ -n "$_b" ] || { echo "OPTIONAL-KEY-PARITY: provider '$_p' has no block in the template" >&2; FAIL=1; return; }
  for _k in "$@"; do printf '%s\n' "$_b" | has_uncommented "$_k" && _ok=1; done
  [ "$_ok" = 1 ] \
    || { echo "OPTIONAL-KEY-PARITY: $_p must have at least one of ($_keys) uncommented in the template — this is an either-or lane contract (e.g. ClickStack = ClickHouse OR HyperDX); the audit needs one usable lane" >&2; FAIL=1; }
}

# --- the contract (keep in lockstep with each audit's doctor gate) ---
req   grafana         url token_env
req   sentry          host org token_env
req   pagerduty       token_env
req   datadog         site api_key_env app_key_env
req   elk             kibana_url token_env
req   jsm             site email_env token_env
req   zenduty         token_env
req   groundcover     token_env
req   lgtm            runtime_mode
req   prometheus      url
req   signoz          url api_key_env
req   loki            url
req   tempo           url
req   mimir           url
req   victoriametrics url
req   digitalocean    token_env
req   gcp             project
req   azure           subscription_id
req   github          org token_env
req   kubernetes      context
req   slack           webhook_env
# ClickStack: at least one LANE (ClickHouse OR HyperDX). Neither individual lane key
# is required — this is the v0.1.149 HyperDX-only contract, encoded so it can't regress.
oneof clickstack      clickhouse_url hyperdx_url
# aws: account_id/region are defaults, not hard-required (the audit runs on the active
# credential chain when account_id is unset, asserting the match only when it is set),
# so they are intentionally unconstrained here.

[ "$FAIL" = 0 ] && echo "OPTIONAL-KEY-PARITY-OK (per-provider required keys + the ClickStack ClickHouse-OR-HyperDX lane contract are reflected in the template)"
exit "$FAIL"
