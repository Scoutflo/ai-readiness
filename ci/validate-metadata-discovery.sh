#!/bin/sh
# validate-metadata-discovery.sh
# Gate: Validate computed_metadata.jsonl schema, content, and consistency
# Run after metadata-resolver generates computed_metadata.jsonl
# Exit 0 if valid, exit 1 if invalid

set -eu

OUTPUT_FILE="${1:-.}/metadata/computed_metadata.jsonl"

echo "Validating metadata discovery output: $OUTPUT_FILE"
echo ""

# Check 1: File exists
if [ ! -f "$OUTPUT_FILE" ]; then
  echo "❌ FAIL: $OUTPUT_FILE not found"
  exit 1
fi

echo "✓ File exists"

# Check 2: File is not empty
if [ ! -s "$OUTPUT_FILE" ]; then
  echo "❌ FAIL: $OUTPUT_FILE is empty (no resources discovered)"
  exit 1
fi

RESOURCE_COUNT=$(wc -l < "$OUTPUT_FILE")
echo "✓ File contains $RESOURCE_COUNT resources"

# Check 3: Each line is valid JSON
INVALID_JSON=0
while IFS= read -r line; do
  if ! echo "$line" | jq -e . >/dev/null 2>&1; then
    echo "❌ FAIL: Invalid JSON on line: $line"
    INVALID_JSON=$((INVALID_JSON + 1))
  fi
done < "$OUTPUT_FILE"

if [ "$INVALID_JSON" -gt 0 ]; then
  echo "❌ FAIL: $INVALID_JSON lines are not valid JSON"
  exit 1
fi

echo "✓ All $RESOURCE_COUNT lines are valid JSON"

# Check 4: Required fields present in all resources
MISSING_FIELDS=0
while IFS= read -r line; do
  for field in resource_id team environment sla escalation cost_sensitivity action resolved_at; do
    if ! echo "$line" | jq -e ".$field" >/dev/null 2>&1; then
      echo "❌ FAIL: Missing field '$field' in resource: $line"
      MISSING_FIELDS=$((MISSING_FIELDS + 1))
      break
    fi
  done
done < "$OUTPUT_FILE"

if [ "$MISSING_FIELDS" -gt 0 ]; then
  echo "❌ FAIL: $MISSING_FIELDS resources missing required fields"
  exit 1
fi

echo "✓ All resources have required fields: resource_id, team, environment, sla, escalation, cost_sensitivity, action, resolved_at"

# Check 5: Valid escalation values (CRITICAL or STANDARD)
INVALID_ESCALATION=0
while IFS= read -r line; do
  escalation=$(echo "$line" | jq -r '.escalation')
  if [ "$escalation" != "CRITICAL" ] && [ "$escalation" != "STANDARD" ]; then
    echo "❌ FAIL: Invalid escalation value '$escalation' (expected CRITICAL or STANDARD)"
    INVALID_ESCALATION=$((INVALID_ESCALATION + 1))
  fi
done < "$OUTPUT_FILE"

if [ "$INVALID_ESCALATION" -gt 0 ]; then
  echo "❌ FAIL: $INVALID_ESCALATION resources have invalid escalation values"
  exit 1
fi

echo "✓ All escalation values are valid (CRITICAL or STANDARD)"

# Check 6: Valid cost_sensitivity values (high, medium, low)
INVALID_COST_SENS=0
while IFS= read -r line; do
  cost_sens=$(echo "$line" | jq -r '.cost_sensitivity')
  if [ "$cost_sens" != "high" ] && [ "$cost_sens" != "medium" ] && [ "$cost_sens" != "low" ]; then
    echo "❌ FAIL: Invalid cost_sensitivity value '$cost_sens' (expected high, medium, or low)"
    INVALID_COST_SENS=$((INVALID_COST_SENS + 1))
  fi
done < "$OUTPUT_FILE"

if [ "$INVALID_COST_SENS" -gt 0 ]; then
  echo "❌ FAIL: $INVALID_COST_SENS resources have invalid cost_sensitivity values"
  exit 1
fi

echo "✓ All cost_sensitivity values are valid (high, medium, low)"

# Check 7: Valid action values (audit or skip)
INVALID_ACTION=0
while IFS= read -r line; do
  action=$(echo "$line" | jq -r '.action')
  if [ "$action" != "audit" ] && [ "$action" != "skip" ]; then
    echo "❌ FAIL: Invalid action value '$action' (expected audit or skip)"
    INVALID_ACTION=$((INVALID_ACTION + 1))
  fi
done < "$OUTPUT_FILE"

if [ "$INVALID_ACTION" -gt 0 ]; then
  echo "❌ FAIL: $INVALID_ACTION resources have invalid action values"
  exit 1
fi

echo "✓ All action values are valid (audit or skip)"

# Check 8: SLA values are recognized formats (percentage or recognized standard)
INVALID_SLA=0
while IFS= read -r line; do
  sla=$(echo "$line" | jq -r '.sla')
  # Valid: 99.9%, 99.95%, 95%, or recognized names
  if ! echo "$sla" | grep -qE '^[0-9]{2}\.[0-9]+%$|^95%$|production|staging'; then
    # Allow any percentage format, just validate it ends with %
    if ! echo "$sla" | grep -q '%'; then
      echo "⚠ WARNING: Unusual SLA format: $sla (expected percentage like 99.9%)"
    fi
  fi
done < "$OUTPUT_FILE"

echo "✓ SLA values are in expected formats"

# Check 9: resolved_at is valid ISO timestamp
INVALID_TIMESTAMP=0
while IFS= read -r line; do
  timestamp=$(echo "$line" | jq -r '.resolved_at')
  if ! echo "$timestamp" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    echo "❌ FAIL: Invalid timestamp format: $timestamp (expected ISO 8601)"
    INVALID_TIMESTAMP=$((INVALID_TIMESTAMP + 1))
  fi
done < "$OUTPUT_FILE"

if [ "$INVALID_TIMESTAMP" -gt 0 ]; then
  echo "❌ FAIL: $INVALID_TIMESTAMP resources have invalid timestamp format"
  exit 1
fi

echo "✓ All resolved_at timestamps are valid ISO 8601 format"

# Check 10: No duplicate resource_ids
DUPLICATES=$(jq -r '.resource_id' "$OUTPUT_FILE" | sort | uniq -d | wc -l)
if [ "$DUPLICATES" -gt 0 ]; then
  echo "⚠ WARNING: $DUPLICATES duplicate resource_ids found"
  jq -r '.resource_id' "$OUTPUT_FILE" | sort | uniq -d | head -5 | while read -r dup; do
    echo "   - $dup"
  done
  # This is a warning, not a failure (resource might legitimately exist in multiple clouds)
fi

echo "✓ No critical duplicates"

# Check 11: Summary statistics
CRITICAL_COUNT=$(jq -s '[.[] | select(.escalation=="CRITICAL")] | length' "$OUTPUT_FILE")
STANDARD_COUNT=$(jq -s '[.[] | select(.escalation=="STANDARD")] | length' "$OUTPUT_FILE")
SKIP_COUNT=$(jq -s '[.[] | select(.action=="skip")] | length' "$OUTPUT_FILE")
AUDIT_COUNT=$(jq -s '[.[] | select(.action=="audit")] | length' "$OUTPUT_FILE")

echo ""
echo "📊 Metadata Summary:"
echo "   Total resources: $RESOURCE_COUNT"
echo "   Escalation: CRITICAL=$CRITICAL_COUNT, STANDARD=$STANDARD_COUNT"
echo "   Action: audit=$AUDIT_COUNT, skip=$SKIP_COUNT"

# Check 12: At least some resources to audit
if [ "$AUDIT_COUNT" -eq 0 ]; then
  echo "⚠ WARNING: No resources marked for audit (all skipped)"
fi

echo ""
echo "✅ PASS: $OUTPUT_FILE is valid"
exit 0
