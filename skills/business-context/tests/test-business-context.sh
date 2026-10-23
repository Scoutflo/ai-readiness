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

echo "Test 9: resource_intent parses only REAL declarations from the closed vocabulary"
# The decisive case is the first assertion: the shipped template's example is
# COMMENTED, and parsing it as a declaration would silently exempt a resource
# nobody declared — a false negative nobody reviews, because the finding is
# never written. Intent is declared, never inferred.
cat >> "$WORK/.scoutflo/business_context.md" <<'MD'

## Resource Intent

```yaml
resource_intent:
  # - cluster: <cluster-name>
  #   intent: standby
  #   why: commented example that must never count as a declaration
  - cluster: standby-cluster
    intent: standby
    why: warm standby sized to take full load on failover
    review_by: 2027-01-01
  - namespace: archive
    intent: backup
    why: nightly archive target
  - workload: mystery
    intent: probably-fine
    why: an invented intent must be dropped, not passed through
  - cluster: <cluster-name>
    intent: dr
    why: an unfilled placeholder must be dropped
  - cluster: commented-tail
    intent: standby
    why: a real declaration whose following keys are commented out
    # intent: by-a-commented-line
    # why: a commented line must never OVERWRITE the entry above it
```
MD
bc_derive_json >/dev/null
ri="$(jq '.resource_intent | length' "$J")"
[ "$ri" -eq 3 ] || fail "expected exactly 3 valid resource_intent entries, got $ri: $(jq -c '.resource_intent' "$J")"
# Comment-immunity here is STRUCTURAL, not guarded by the explicit `/^#/` skip:
# a commented `# intent: x` parses its key as "# intent", which matches no known
# key, so it is inert either way (verified: removing both `/^#/` filters leaves
# this suite green). The skip stays as defence-in-depth for future key handling.
# What IS load-bearing and proven by this test: the closed-vocabulary filter and
# the placeholder filter — removing either fails the assertions below.
jq -e '.resource_intent[] | select(.match=="commented-tail" and .intent=="standby" and (.why|test("real declaration")))' "$J" >/dev/null \
  || fail "commented key lines overwrote the declaration above them: $(jq -c '.resource_intent' "$J")"
jq -e '.resource_intent[] | select((.intent=="by-a-commented-line") or (.why|test("must never OVERWRITE")))' "$J" >/dev/null \
  && fail "a commented key line was parsed as a real value"
jq -e '.resource_intent[] | select(.match=="standby-cluster" and .intent=="standby" and .review_by=="2027-01-01" and (.why|length>0))' "$J" >/dev/null \
  || fail "the declared standby entry did not parse with its why and review_by"
jq -e '.resource_intent[] | select(.match=="archive" and .intent=="backup" and .match_kind=="namespace")' "$J" >/dev/null \
  || fail "the namespace-matched backup entry did not parse"
jq -e '.resource_intent[] | select(.intent=="probably-fine")' "$J" >/dev/null \
  && fail "an intent outside the closed vocabulary reached the projection"
jq -e '.resource_intent[] | select(.match|test("^<"))' "$J" >/dev/null \
  && fail "an unfilled <placeholder> was treated as a real declaration"
jq -e '.resource_intent[] | select(.why|test("commented example"))' "$J" >/dev/null \
  && fail "a COMMENTED template example became a live declaration — this would silently exempt an undeclared resource"
echo "PASS"

echo "Test 10: the shipped template alone declares NOTHING"
# A fresh SSOT copied from the template must yield zero intents and zero units. If
# the template's own example ever counts, every customer who runs the skill gets a
# silent exemption or a fabricated denominator. This is an end-to-end property of
# the shipped artifact, not a test of one guard: it would catch a template edit
# that uncomments an example just as surely as a parser regression.
cp "$ROOT/templates/business_context_template.md" "$WORK/.scoutflo/business_context.md"
bc_derive_json >/dev/null
[ "$(jq '.resource_intent | length' "$J")" -eq 0 ] \
  || fail "the shipped template produced resource_intent declarations: $(jq -c '.resource_intent' "$J")"
[ "$(jq '.unit_metrics | length' "$J")" -eq 0 ] \
  || fail "the shipped template produced unit_metrics declarations: $(jq -c '.unit_metrics' "$J")"
echo "PASS"

echo "Test 11: unit_metrics parses only REAL declarations from the closed source set"
# Same two rules as resource_intent, for a sharper reason: a WRONG denominator is
# harder to spot than a missing one, because the number looks finished. A unit the
# customer never declared would publish a confident cost-per-unit measuring nothing.
cat >> "$WORK/.scoutflo/business_context.md" <<'MD'

## Unit of Delivered Value

```yaml
unit_metrics:
  # - name: "<commented example>"
  #   query: 'never_counts'
  #   source: prometheus
  - name: "meeting minutes"
    query: 'sum(increase(app_minutes_total{job="api",env!~"dev|test"}[30d]))'
    source: prometheus
    scope: namespace:prod
    per: 1000
  - name: recordings
    query: sum(increase(rec_total[30d]))   # a trailing comment must be stripped
    source: cloud-monitoring
  - name: bogus
    query: 'x'
    source: datadog
  - name: "<what you count, in your words>"
    query: '<your own metric query>'
    source: prometheus
```
MD
bc_derive_json >/dev/null
um="$(jq '.unit_metrics | length' "$J")"
[ "$um" -eq 2 ] || fail "expected exactly 2 valid unit_metrics, got $um: $(jq -c '.unit_metrics' "$J")"
# The query is the customer's own PromQL: quotes, braces, brackets and !~ must survive
# BYTE-IDENTICAL. jq does the JSON encoding precisely so this cannot be corrupted.
q="$(jq -r '.unit_metrics[] | select(.name=="meeting minutes") | .query' "$J")"
[ "$q" = 'sum(increase(app_minutes_total{job="api",env!~"dev|test"}[30d]))' ] \
  || fail "the declared PromQL query was not preserved verbatim: $q"
jq -e '.unit_metrics[] | select(.name=="recordings" and .query=="sum(increase(rec_total[30d]))" and .scope=="all" and .per==1000)' "$J" >/dev/null \
  || fail "trailing comment not stripped, or scope/per defaults not applied: $(jq -c '.unit_metrics' "$J")"
jq -e '.unit_metrics[] | select(.source=="datadog")' "$J" >/dev/null \
  && fail "a source outside the closed set reached the projection"
jq -e '.unit_metrics[] | select((.name|test("^<")) or (.query|test("^<")))' "$J" >/dev/null \
  && fail "an unfilled <placeholder> was treated as a real declaration"
jq -e '.unit_metrics[] | select(.query=="never_counts")' "$J" >/dev/null \
  && fail "a COMMENTED template example became a live unit declaration"
echo "PASS"

echo "Test 12: free text containing a backslash or a quote does not silently drop a declaration"
# Hand-built JSON in awk made this a SILENT data loss: an invalid \escape made jq
# emit [] and every declaration vanished with no error in the file. Letting jq do
# the encoding is what fixes it, so this test guards the technique, not the text.
cp "$ROOT/templates/business_context_template.md" "$WORK/.scoutflo/business_context.md"
cat >> "$WORK/.scoutflo/business_context.md" <<'MD'

## Resource Intent

```yaml
resource_intent:
  - cluster: dr-west
    intent: standby
    why: warm standby for "primary"; runbook at C:\dr\plan — holds 100% capacity
  - namespace: archive
    intent: backup
    why: nightly archive target
```
MD
err="$(bc_derive_json 2>&1 >/dev/null)"
[ -z "$err" ] || fail "bc_derive_json wrote to stderr on valid input (a count built with echo mangles backslashes): $err"
ri2="$(jq '.resource_intent | length' "$J")"
[ "$ri2" -eq 2 ] || fail "expected 2 declarations to survive quotes/backslashes, got $ri2: $(jq -c '.resource_intent' "$J")"
jq -e '.resource_intent[] | select(.match=="dr-west" and (.why|test("C:")) and (.why|test("\"primary\"")))' "$J" >/dev/null \
  || fail "the why text lost its quotes or its backslash path"
echo "PASS"

echo
echo "=== business-context SSOT tests passed ==="
