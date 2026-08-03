#!/bin/sh
# test-business-context.sh
# Exercises the rebuilt business-context lib: it must produce the
# business_context.md SSOT (not topology.json scalars), pass the shipped
# validator, and derive a business_context.json the shell libs can read —
# including the per-environment map and critical services. Runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
LIB="$ROOT/skills/business-context/lib/business-context.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"          # sandbox ~/.scoutflo into the temp dir
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

. "$LIB"

echo "=== business-context (SSOT rebuild) tests ==="

echo "Test 1: scaffold writes business_context.md (the SSOT), not topology.json"
bc_scaffold_from_template >/dev/null
[ -f "$WORK/.scoutflo/business_context.md" ] || fail "business_context.md not created"
[ ! -f "$WORK/.scoutflo/topology.json" ] || fail "scaffold wrongly wrote topology.json"
echo "PASS"

echo "Test 2: the scaffolded SSOT passes the shipped validator"
bc_validate "$WORK/.scoutflo/business_context.md" >/dev/null 2>&1 || fail "scaffolded SSOT fails ci/validate-business-context.sh"
echo "PASS"

echo "Test 3: bc_derive_json produces business_context.json with the core fields"
sed -i.bak 's/^- \*\*Stage:\*\* \[.*\]/- **Stage:** staging/' "$WORK/.scoutflo/business_context.md"
sed -i.bak2 's/^- \*\*Primary:\*\* \[.*\]/- **Primary:** high/' "$WORK/.scoutflo/business_context.md"
rm -f "$WORK/.scoutflo/business_context.md.bak"*
bc_derive_json >/dev/null
J="$WORK/.scoutflo/business_context.json"
[ -f "$J" ] || fail "business_context.json not derived"
[ "$(jq -r '.environment' "$J")" = "staging" ] || fail "environment not derived (got $(jq -r .environment "$J"))"
[ "$(jq -r '.cost_sensitivity' "$J")" = "high" ] || fail "cost_sensitivity not derived (got $(jq -r .cost_sensitivity "$J"))"
echo "PASS"

echo "Test 4: critical services parse into critical_dependencies[]"
awk '1; /^## Critical Services/ && !done { print ""; print "- `payments-api` (revenue)"; print "- `checkout-svc` (customer-facing)"; done=1 }' \
  "$WORK/.scoutflo/business_context.md" > "$WORK/bc2.md" && mv "$WORK/bc2.md" "$WORK/.scoutflo/business_context.md"
bc_derive_json >/dev/null
n="$(jq '.critical_dependencies | length' "$J")"
[ "$n" -ge 2 ] || fail "expected >=2 critical_dependencies, got $n"
jq -e '.critical_dependencies | index("payments-api")' "$J" >/dev/null || fail "payments-api not in critical_dependencies"
echo "PASS"

echo "Test 5: paste mode appends verbatim under Custom Rules and re-derives"
printf 'Never page on-call for staging between 22:00-07:00 IST.\n' | bc_append_custom >/dev/null
grep -q 'Never page on-call for staging' "$WORK/.scoutflo/business_context.md" || fail "pasted rule not appended to SSOT"
echo "PASS"

echo "Test 6: import adopts an external file as the SSOT after validating it"
cat > "$WORK/mine.md" <<'MD'
# Business Context — Acme
## Environment
- **Stage:** production
## Cost Sensitivity
- **Primary:** low
MD
bc_import_file "$WORK/mine.md" >/dev/null
grep -q 'Acme' "$WORK/.scoutflo/business_context.md" || fail "imported file not adopted as SSOT"
[ "$(jq -r '.cost_sensitivity' "$J")" = "low" ] || fail "derived json not refreshed after import (got $(jq -r .cost_sensitivity "$J"))"
echo "PASS"

echo "Test 7: migration seeds the SSOT from a legacy topology.json:.business_context"
rm -f "$WORK/.scoutflo/business_context.md" "$J"
mkdir -p "$WORK/.scoutflo"
printf '%s\n' '{"business_context":{"team":"platform","environment":"dr","cost_sensitivity":"high"},"audit_scope":{"services":["x"]}}' > "$WORK/.scoutflo/topology.json"
bc_migrate_from_topology >/dev/null
[ -f "$WORK/.scoutflo/business_context.md" ] || fail "migration did not create the SSOT"
[ "$(jq -r '.environment' "$J")" = "dr" ] || fail "migrated environment wrong (got $(jq -r .environment "$J"))"
jq -e '.audit_scope' "$WORK/.scoutflo/topology.json" >/dev/null || fail "migration destroyed checkpoint's audit_scope in topology.json"
echo "PASS"

echo "Test 8: per-environment map parses (profile + SLA per environment)"
cat >> "$WORK/.scoutflo/business_context.md" <<'MD'

## Environment Map (per-environment access + SLA)

| Environment | AWS profile | GCP project | K8s context / cluster | Region | Uptime SLA | Notes |
|---|---|---|---|---|---|---|
| production | prod-profile | prod-proj | prod-ctx | us-east-1 | 99.95% | main |
| staging | stg-profile | stg-proj | stg-ctx | us-east-1 | 99.5% | lower |
MD
bc_derive_json >/dev/null
em="$(jq '.environment_map | length' "$J")"
[ "$em" -ge 2 ] || fail "expected >=2 environment_map rows, got $em"
jq -e '.environment_map[] | select(.environment=="staging" and .aws_profile=="stg-profile" and .uptime_sla=="99.5%")' "$J" >/dev/null \
  || fail "staging env-map row (profile+SLA) not parsed"
echo "PASS"

echo
echo "=== business-context SSOT tests passed ==="
